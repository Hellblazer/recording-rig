// SPDX-License-Identifier: MIT
//
// Keeps the display awake for the length of a capture. With the display asleep,
// ScreenCaptureKit delivers only `.idle` frames for a window, never `.complete`,
// so the writer session (started on the first complete frame) never starts and
// the run records nothing. Measured 2026-11-12 on a MacBook with displaysleep 10:
// display off, 452 frames all idle; display on, 427 frames all complete.
//
// The driver is usually run unattended, so the 10-minute display sleep between
// runs is the common case, not an edge.

import Foundation
import IOKit.pwr_mgt

final class DisplayWake {
    private var userActivity: IOPMAssertionID = 0
    private var noDisplaySleep: IOPMAssertionID = 0

    /// Wake the display now and hold it awake until `release()`.
    func hold(reason: String) {
        let name = reason as CFString
        // Declaring user activity turns a sleeping display on; the second
        // assertion keeps the idle timer from turning it off mid-run.
        if IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveLocal, &userActivity) != kIOReturnSuccess {
            userActivity = 0
            log("could not declare user activity; the display may stay asleep")
        }
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), name,
                                       &noDisplaySleep) != kIOReturnSuccess {
            noDisplaySleep = 0
            log("could not hold the display awake; a long run may lose frames")
        }
    }

    func release() {
        for id in [userActivity, noDisplaySleep] where id != 0 {
            IOPMAssertionRelease(id)
        }
        userActivity = 0
        noDisplaySleep = 0
    }

    deinit { release() }
}
