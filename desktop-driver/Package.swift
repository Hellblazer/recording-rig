// swift-tools-version:5.10
// SPDX-License-Identifier: MIT
//
// bin/desktop-driver (RDR-001 Phase 2 Step 1, rr-2pp.3.1).
//
// DesktopDriverCore  — pure, hermetically-testable logic (Foundation only):
//                      selector decode, the active-session/config contract,
//                      the atomic sentinel write, the armWait retry/timeout
//                      loop, geometry re-assert. No AppKit / AX / ScreenCaptureKit
//                      so `swift test` runs without a live app or TCC grants.
// desktop-driver     — the thin executable: wires the real ApplicationServices
//                      (AXUIElement) + ScreenCaptureKit providers and the
//                      NSApplication(.accessory) bootstrap. The live AX-drive +
//                      capture sequence is exercised by the rr-2pp.3.6 e2e gate,
//                      not by unit tests.
import PackageDescription

let package = Package(
    name: "desktop-driver",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DesktopDriverCore"),
        .executableTarget(
            name: "desktop-driver",
            dependencies: ["DesktopDriverCore"]
        ),
        // Read-only AX-tree dumper for surface-selector discovery (rr-2pp.5.1).
        // Self-contained (ApplicationServices only) so it cannot affect the
        // shipping driver target; staged to bin/ax-dump by build-ax-dump.sh.
        .executableTarget(name: "ax-dump"),
        // TCC preflight reporter for `doctor` desktop mode (rr-2pp.6.1.1).
        // Self-contained (AppKit + ApplicationServices); prints
        // {accessibility,screenRecording} JSON. Staged to bin/perms-check by
        // build-perms-check.sh.
        .executableTarget(name: "perms-check"),
        .testTarget(
            name: "DesktopDriverCoreTests",
            dependencies: ["DesktopDriverCore"]
        ),
    ]
)
