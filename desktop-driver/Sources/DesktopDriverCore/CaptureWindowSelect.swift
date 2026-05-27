// SPDX-License-Identifier: MIT
import Foundation

/// A minimal, framework-free descriptor of a capturable window — enough to choose
/// the right one without depending on ScreenCaptureKit, so the choice is unit-testable.
public struct WindowCandidate: Equatable {
    public let pid: pid_t
    public let isOnScreen: Bool
    public let area: Double
    public init(pid: pid_t, isOnScreen: Bool, area: Double) {
        self.pid = pid
        self.isOnScreen = isOnScreen
        self.area = area
    }
}

/// Choose which window to screen-capture for the Claude-Rig pid.
///
/// rr-79v: Claude.app v1.9255.0 began exposing a small secondary on-screen window
/// (~280x320) for the same pid. Capturing the *first* matching window grabbed that
/// tiny black region instead of the main chat window the AX driver had sized to the
/// recording geometry. Choose the **largest** on-screen window owned by `rigPid`
/// instead — the main window dominates any panel/popover by area.
///
/// Returns the index into `windows`, or `nil` if no on-screen window belongs to the
/// pid. Equal areas resolve to the earliest index (deterministic; strict `>` below).
public func selectCaptureWindowIndex(_ windows: [WindowCandidate], rigPid: pid_t) -> Int? {
    var best: Int?
    for (i, w) in windows.enumerated() where w.pid == rigPid && w.isOnScreen {
        if let b = best {
            if w.area > windows[b].area { best = i }
        } else {
            best = i
        }
    }
    return best
}
