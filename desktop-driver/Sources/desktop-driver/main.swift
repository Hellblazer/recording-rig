// SPDX-License-Identifier: MIT
//
// bin/desktop-driver — RDR-001 Phase 2 Step 1 (rr-2pp.3.1).
//
// Thin executable: parse the launch config + spec + selectors (all tested in
// DesktopDriverCore), bootstrap NSApplication as .accessory BEFORE any
// CoreGraphics/ScreenCaptureKit call (else CGS_REQUIRE_INIT), then run the live
// AX-drive + ScreenCaptureKit capture sequence against AXDriver / ScreenCaptureSink.
//
// The live sequence is compile-verified only; its runtime behavior (real AX
// attach, nav, submit, capture) is gated by the rr-2pp.3.6 e2e gate, which needs
// a live Claude-Rig + granted Accessibility/Screen-Recording TCC. The mandatory
// invariant code-review is rr-2pp.3.5.
//
// Division of labor (RDR L207/L248/L548): record.sh owns SESSION, the
// active-session/rig-config writes, the launch, and the turn-end sentinel WATCH;
// when the turn idles it writes `agent-done`. This driver owns AX-drive +
// capture: it drives the command, submits, writes `prompt-submitted`, records,
// then waits for `agent-done` to flush the .mov and exit.

import AppKit
import DesktopDriverCore
import Foundation

func log(_ message: String) {
    FileHandle.standardError.write(Data("[desktop-driver] \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    log("fatal: \(message)")
    exit(2)
}

let config: DriverConfig
let spec: DriverSpec
let selectors: SurfaceSelectors
do {
    config = try DriverConfig.parse(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    spec = try SpecReader.load(path: config.specPath)

    // Selectors file sits beside the binary (bin/desktop-ax-selectors.json),
    // overridable via RIG_SELECTORS for non-standard layouts / tests.
    let selectorsPath = ProcessInfo.processInfo.environment["RIG_SELECTORS"]
        ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("desktop-ax-selectors.json").path
    selectors = try Selectors.load(path: selectorsPath).surface(spec.surface)
} catch {
    fail("\(error)")
}

// INVARIANT: init NSApplication as .accessory before any CG/SCK usage.
NSApplication.shared.setActivationPolicy(.accessory)

log("pid=\(config.rigPid) session=\(config.session) surface=\(spec.surface) commands=\(spec.commands.count)")

let ax = AXDriver(rigPid: config.rigPid)
let sentinels = SentinelWriter(directory: config.tmpRoot, session: config.session)
let capture = ScreenCaptureSink(rigPid: config.rigPid, outputPath: "\(config.tmpRoot)/\(config.session).mov")
let waiter = WaitForStable()

// armWait helper: re-arm AXManualAccessibility before every probe (INVARIANT 1).
func armWait(role: String, description: String, timeout: Double = 30, poll: Double = 0.5) -> AXDriver.Element {
    do {
        return try waiter.wait(label: "\(role):\(description)", timeout: timeout, poll: poll,
                               rearm: { ax.armManualAccessibility() }) {
            ax.find(role: role, description: description)
        }
    } catch {
        fail("\(error)")
    }
}

do {
    // 1. Window geometry — set, then re-assert if it reverted.
    if ax.setWindowSize(spec.recordingSize),
       sizeNeedsReassert(current: ax.windowSize(), target: spec.recordingSize) {
        _ = ax.setWindowSize(spec.recordingSize)
    }

    // 2. Navigate to the surface tab.
    let navButton = armWait(role: selectors.navButton.role, description: selectors.navButton.axDescription)
    guard ax.press(navButton) else { fail("AXPress failed on \(spec.surface) nav button") }

    // rr-2pp.3.1 drives the first command (the MVV gate uses one). Multi-command
    // desktop pacing (wait for each turn to idle before the next paste) is wired
    // with the record.sh desktop dispatch (rr-2pp.3.3).
    guard let command = spec.commands.first else { fail("no command to drive") }

    // 3. Composer: set the prompt value (element-scoped, safe).
    let composer = armWait(role: selectors.composer.role, description: selectors.composer.axDescription)
    guard ax.setValue(composer, command) else { fail("AXValue set failed on composer") }

    // 4. Start capture BEFORE the submit (writer session begins on the first
    //    frame's PTS, ahead of the first model output).
    try capture.start()

    // 5. Submit via a process-targeted Return (INVARIANT 2), then record the
    //    prompt-submitted sentinel — the driver's analogue of the CLI's
    //    UserPromptSubmit hook.
    ax.postReturnKeyToRig()
    try sentinels.writeMarker("prompt-submitted")
    log("submitted; recording -> \(config.tmpRoot)/\(config.session).mov; waiting for agent-done")

    // 6. record.sh owns the turn-end watch; it writes agent-done when the turn
    //    idles. Wait for it (session ceiling), then flush the capture.
    let agentDone = "\(config.tmpRoot)/\(config.session).agent-done"
    _ = try waiter.wait(label: "agent-done", timeout: 1800, poll: 1) {
        FileManager.default.fileExists(atPath: agentDone) ? true : nil
    }

    // 7. Teardown: stop the stream + finishWriting() to flush the .mov.
    try capture.finish()
    log("capture flushed; done")
    exit(0)
} catch {
    // Best-effort flush so a partial recording is still inspectable.
    try? capture.finish()
    fail("\(error)")
}
