// SPDX-License-Identifier: MIT
import Foundation

/// AX-driving seam. The executable target implements this against
/// ApplicationServices (`AXUIElement`) + CoreGraphics (`CGEvent`); the core and
/// its tests depend only on the protocol. `Element` is the opaque handle type
/// (a real `AXUIElement` in production, a fake in tests).
///
/// INVARIANT 1 (armManualAccessibility + re-find before every action) is
/// enforced by `WaitForStable`; this protocol exposes the primitives it drives.
/// INVARIANT 2 (NEVER a global `CGEvent.post(tap:)`) is encoded by exposing only
/// `postReturnKeyToRig()` — a process-targeted `postToPid(rigPid)` — and no
/// global-post primitive at all, so the leak-prone call has no seam to reach.
public protocol AXDriving {
    associatedtype Element

    /// Re-set `AXManualAccessibility` on the app element (the tree collapses
    /// across re-renders; this is the "re-arm" half of armWait).
    func armManualAccessibility()

    /// Walk the (freshly re-armed) tree for a role + AXDescription match.
    /// Returns nil when absent so `WaitForStable` can poll.
    func find(role: String, description: String) -> Element?

    @discardableResult func press(_ element: Element) -> Bool
    @discardableResult func setValue(_ element: Element, _ value: String) -> Bool

    func windowSize() -> Size?
    @discardableResult func setWindowSize(_ size: Size) -> Bool

    /// Submit: process-targeted Return key to the Claude-Rig PID only.
    /// (The implementation uses `CGEvent(...).postToPid(rigPid)`.)
    func postReturnKeyToRig()
}

/// Screen-capture seam. The executable target implements this against
/// ScreenCaptureKit (`SCStream` + `AVAssetWriter`); the live capture is
/// exercised only by the rr-2pp.3.6 e2e gate.
public protocol CaptureSink {
    /// Begin capture of the Claude-Rig window; the writer session starts on the
    /// first frame's PTS (before the first paste).
    func start() throws
    /// Stop the stream and `finishWriting()` to flush the `.mov` (teardown).
    func finish() throws
}
