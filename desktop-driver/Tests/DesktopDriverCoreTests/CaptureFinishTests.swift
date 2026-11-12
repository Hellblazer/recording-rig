// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class CaptureFinishTests: XCTestCase {
    func testFinishesOnlyWhileWriting() {
        XCTAssertTrue(CaptureFinish.mayFinishWriting(writerStatus: CaptureFinish.writerStatusWriting))
    }

    func testNeverFinishesAWriterThatNeverStarted() {
        // status 0 is "unknown": no frame arrived, no session started; markAsFinished would throw.
        XCTAssertFalse(CaptureFinish.mayFinishWriting(writerStatus: CaptureFinish.writerStatusUnknown))
    }

    func testNeverFinishesACompletedFailedOrCancelledWriter() {
        for status in [2, 3, 4] {
            XCTAssertFalse(CaptureFinish.mayFinishWriting(writerStatus: status), "status \(status)")
        }
    }
}
