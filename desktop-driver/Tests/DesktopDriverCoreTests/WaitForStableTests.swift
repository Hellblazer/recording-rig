// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class WaitForStableTests: XCTestCase {
    /// A hermetic clock: `sleep` advances virtual time, so timeout/retry are
    /// tested without real wall-clock waits.
    private final class FakeClock {
        var t = 0.0
        func now() -> Double { t }
        func sleep(_ d: Double) { t += d }
    }

    func testReturnsAfterElementAppears() throws {
        let clock = FakeClock()
        let w = WaitForStable(now: clock.now, sleep: clock.sleep)
        var rearms = 0
        var polls = 0
        let value: String = try w.wait(label: "composer", timeout: 10, poll: 1, rearm: { rearms += 1 }) {
            polls += 1
            return polls >= 3 ? "found" : nil  // appears on the 3rd probe
        }
        XCTAssertEqual(value, "found")
        XCTAssertEqual(polls, 3)
        XCTAssertEqual(rearms, 3, "re-arms before every probe (INVARIANT 1)")
    }

    func testTimesOutAndFailsLoud() {
        let clock = FakeClock()
        let w = WaitForStable(now: clock.now, sleep: clock.sleep)
        XCTAssertThrowsError(
            try w.wait(label: "AXButton:Chat", timeout: 5, poll: 1) { Optional<String>.none }
        ) {
            guard case let DriverError.timeout(msg) = $0 else {
                return XCTFail("expected timeout, got \($0)")
            }
            XCTAssertTrue(msg.contains("AXButton:Chat"), "names the element it waited for")
        }
    }

    func testSucceedsOnFirstProbeWithoutSleeping() throws {
        let clock = FakeClock()
        let w = WaitForStable(now: clock.now, sleep: clock.sleep)
        let v: Int = try w.wait(label: "x", timeout: 3, poll: 1) { 7 }
        XCTAssertEqual(v, 7)
        XCTAssertEqual(clock.t, 0, "no sleep when the element is already present")
    }
}
