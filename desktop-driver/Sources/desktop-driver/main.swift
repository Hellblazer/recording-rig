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
let allSelectors: Selectors
do {
    config = try DriverConfig.parse(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    spec = try SpecReader.load(path: config.specPath)

    // Selectors file sits beside the binary (bin/desktop-ax-selectors.json),
    // overridable via RIG_SELECTORS for non-standard layouts / tests. Kept whole
    // (not pre-resolved to one surface) so the step loop can resolve each step's
    // surface (rr-u07 multi-surface choreography).
    let selectorsPath = ProcessInfo.processInfo.environment["RIG_SELECTORS"]
        ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("desktop-ax-selectors.json").path
    allSelectors = try Selectors.load(path: selectorsPath)
} catch {
    fail("\(error)")
}

// INVARIANT: init NSApplication as .accessory before any CG/SCK usage.
NSApplication.shared.setActivationPolicy(.accessory)

log("pid=\(config.rigPid) session=\(config.session) steps=\(spec.steps.count) surfaces=\(spec.steps.map { $0.surface }.joined(separator: ","))")

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

// Like armWait, but resolves the composer among ALL role+description matches via
// findComposer (prefers the focused / on-screen one). Used at compose time so a
// transient composer left mid-surface-transition is not the one we drive (rr-bw3).
func armWaitComposer(role: String, description: String, timeout: Double = 30, poll: Double = 0.5) -> AXDriver.Element {
    do {
        return try waiter.wait(label: "composer \(role):\(description)", timeout: timeout, poll: poll,
                               rearm: { ax.armManualAccessibility() }) {
            ax.findComposer(role: role, description: description)
        }
    } catch {
        fail("\(error)")
    }
}

do {
    // 0. Foreground the Rig instance (rr-re6) — once, before driving. A backgrounded
    //    Electron window collapses its Chromium a11y tree (armWait then times out)
    //    AND renders black, so bring it forward and let it settle. The rr-re6
    //    record.sh guard ensures no competing Claude.app instance steals it back.
    ax.armManualAccessibility()
    ax.bringToFront()
    NSRunningApplication(processIdentifier: config.rigPid)?.activate()
    Thread.sleep(forTimeInterval: 1.5)

    // 1. Window geometry — set once, re-assert if it reverted.
    if ax.setWindowSize(spec.recordingSize),
       sizeNeedsReassert(current: ax.windowSize(), target: spec.recordingSize) {
        _ = ax.setWindowSize(spec.recordingSize)
    }

    // 2. Announce the step count so record.sh's per-step watch loop knows how many
    //    turns to coordinate (rr-u07); it cross-checks this against its own spec read.
    try sentinels.write(suffix: "steps-total", content: String(spec.steps.count))

    // 3. Drive each step in order on its surface, within ONE continuous capture. Per
    //    step: nav to that surface's tab, set the composer (prologue delivered as
    //    composer text — Claude.app has no system-prompt flag), submit, write
    //    `step-K-submitted` (carrying the surface), then wait for record.sh's
    //    `step-K-done` (it runs the turn-end watch for THAT surface's coordination
    //    provider). The window-level capture records the tab switches between steps.
    for (k, step) in spec.steps.enumerated() {
        let sel = try allSelectors.surface(step.surface)

        let navButton = armWait(role: sel.navButton.role, description: sel.navButton.axDescription)
        guard ax.press(navButton) else { fail("AXPress failed on \(step.surface) nav button (step \(k))") }

        let prompt = step.systemPromptPrologue.map { "\($0)\n\n\(step.command)" } ?? step.command

        // Settle after the surface switch — the SPA re-renders asynchronously, so a
        // composer resolved instantly can be transient (rr-bw3). armWaitComposer
        // prefers the focused / on-screen composer among ALL matches, so we drive the
        // visible one, not a stale/transient node left from the previous surface.
        Thread.sleep(forTimeInterval: 0.6)
        let composer = armWaitComposer(role: sel.composer.role, description: sel.composer.axDescription)
        guard ax.setValue(composer, prompt) else { fail("AXValue set failed on composer (step \(k))") }
        // We deliberately do NOT gate on a kAXValue read-back: these are contenteditable
        // editors whose kAXValue does not reflect a programmatic set, so an exact
        // read-back fails even on surfaces that submit fine (e.g. Code). Log the
        // read-back length only, as a diagnostic for future investigation (rr-bw3).
        log("step \(k) (\(step.surface)) composed (read-back chars=\(ax.value(composer)?.count ?? -1))")

        // Start capture before the FIRST submit (writer session begins on the first
        // frame's PTS, ahead of the first model output); later steps share it.
        if k == 0 { try capture.start() }

        // Submit via the process-targeted Return (INVARIANT 2). `step-K-submitted`
        // carries the surface; `prompt-submitted` is kept as a step-0 alias for the
        // existing single-turn consumers (e.g. bin/desktop-gate-smoke.sh).
        ax.postReturnKeyToRig()
        try sentinels.write(suffix: "step-\(k)-submitted", content: step.surface)
        if k == 0 { try sentinels.writeMarker("prompt-submitted") }
        log("step \(k) (\(step.surface)) submitted; waiting for step-\(k)-done")

        let stepDone = sentinels.path("step-\(k)-done")
        _ = try waiter.wait(label: "step-\(k)-done", timeout: 1800, poll: 1) {
            FileManager.default.fileExists(atPath: stepDone) ? true : nil
        }
    }

    // 4. record.sh writes agent-done after the last step's turn-end — the final
    //    flush signal (teardown timing stays with record.sh, as in the single-turn
    //    contract). Wait for it, then stop the stream + finishWriting().
    let agentDone = sentinels.path("agent-done")
    _ = try waiter.wait(label: "agent-done", timeout: 1800, poll: 1) {
        FileManager.default.fileExists(atPath: agentDone) ? true : nil
    }
    try capture.finish()
    log("capture flushed; done")
    exit(0)
} catch {
    // Best-effort flush so a partial recording is still inspectable.
    try? capture.finish()
    fail("\(error)")
}
