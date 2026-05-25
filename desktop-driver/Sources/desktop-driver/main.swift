// SPDX-License-Identifier: MIT
//
// bin/desktop-driver — RDR-001 Phase 2 Step 1 (rr-2pp.3.1).
//
// Thin executable: parse the launch config (tested in DesktopDriverCore),
// bootstrap NSApplication as .accessory BEFORE any CoreGraphics/ScreenCaptureKit
// call (else CGS_REQUIRE_INIT crash — RDR §Technical Design), then run the live
// AX-drive + ScreenCaptureKit capture sequence.
//
// STATUS (rr-2pp.3.1): the testable core (config, selectors, sentinel write,
// armWait, geometry) is implemented and unit-tested. The live AX/SCK providers
// + the drive/capture sequence are the remaining part of this bead and are
// validated by the rr-2pp.3.6 e2e gate (they require a live Claude-Rig + granted
// Accessibility/Screen-Recording TCC, so they cannot be unit-tested). They land
// behind the protocol seams (AXDriving / CaptureSink) in DesktopDriverCore.

import AppKit
import DesktopDriverCore
import Foundation

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[desktop-driver] \(msg)\n".utf8))
}

do {
    let config = try DriverConfig.parse(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    // INVARIANT: init NSApplication as .accessory before any CG/SCK usage.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    log("configured: pid=\(config.rigPid) session=\(config.session) spec=\(config.specPath) tmpRoot=\(config.tmpRoot)")

    // The driver writes exactly one sentinel; the bridge writes the rest.
    let sentinels = SentinelWriter(directory: config.tmpRoot, session: config.session)
    _ = sentinels  // wired here; the live submit step calls writeMarker("prompt-submitted").

    // TODO(rr-2pp.3.1 live, gated by rr-2pp.3.6): implement AXDriving against
    // ApplicationServices (AXManualAccessibility, armWait nav/composer, AXValue
    // set, postToPid Return) + CaptureSink against ScreenCaptureKit (SCStream +
    // AVAssetWriter h264 .mov, finishWriting() teardown), then run:
    //   armWait nav -> press; geometry set+re-assert; armWait composer ->
    //   setValue; capture.start(); postReturnKeyToRig(); sentinels.writeMarker
    //   ("prompt-submitted"); wait for turn-end; capture.finish(); teardown.
    log("core wired; live AX/SCK sequence pending (rr-2pp.3.1 live half, gated by rr-2pp.3.6)")
    exit(0)
} catch {
    log("fatal: \(error)")
    exit(2)
}
