// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class GeometryTests: XCTestCase {
    private let target = Size(width: 1280, height: 800)

    func testReassertWhenUnknown() {
        XCTAssertTrue(sizeNeedsReassert(current: nil, target: target))
    }

    func testReassertWhenDrifted() {
        XCTAssertTrue(sizeNeedsReassert(current: Size(width: 1024, height: 768), target: target))
    }

    func testNoReassertWhenStable() {
        XCTAssertFalse(sizeNeedsReassert(current: Size(width: 1280, height: 800), target: target))
    }
}
