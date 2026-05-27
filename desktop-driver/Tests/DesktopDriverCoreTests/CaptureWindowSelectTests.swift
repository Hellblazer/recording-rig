// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class CaptureWindowSelectTests: XCTestCase {
    // rr-79v: Claude.app v1.9255.0 added a small secondary on-screen window
    // (~280x320). Capturing `.first` matching window grabbed that tiny black
    // region instead of the main chat window — the capture must pick the LARGEST.
    func testPicksLargestOnScreenWindowForRigPid() {
        let rig: pid_t = 42
        let windows = [
            WindowCandidate(pid: 42, isOnScreen: true, area: 280 * 320),   // the v1.9255.0 trap (first)
            WindowCandidate(pid: 42, isOnScreen: true, area: 1280 * 800),  // main window
            WindowCandidate(pid: 99, isOnScreen: true, area: 3000 * 2000), // another app, bigger — must be ignored
        ]
        XCTAssertEqual(selectCaptureWindowIndex(windows, rigPid: rig), 1)
    }

    func testIgnoresOffScreenWindows() {
        let rig: pid_t = 7
        let windows = [
            WindowCandidate(pid: 7, isOnScreen: false, area: 1280 * 800), // off-screen main — excluded
            WindowCandidate(pid: 7, isOnScreen: true, area: 280 * 320),   // only on-screen one for the pid
        ]
        XCTAssertEqual(selectCaptureWindowIndex(windows, rigPid: rig), 1)
    }

    func testNilWhenNoOnScreenWindowForRigPid() {
        let rig: pid_t = 7
        let windows = [
            WindowCandidate(pid: 7, isOnScreen: false, area: 1280 * 800),
            WindowCandidate(pid: 99, isOnScreen: true, area: 1280 * 800),
        ]
        XCTAssertNil(selectCaptureWindowIndex(windows, rigPid: rig))
    }

    func testEqualAreaResolvesToEarliestIndex() {
        let rig: pid_t = 1
        let windows = [
            WindowCandidate(pid: 1, isOnScreen: true, area: 1000),
            WindowCandidate(pid: 1, isOnScreen: true, area: 1000),
        ]
        XCTAssertEqual(selectCaptureWindowIndex(windows, rigPid: rig), 0)
    }
}
