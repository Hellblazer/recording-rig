// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class ComposerSelectTests: XCTestCase {
    // rr-bw3: when the driver switches surfaces (Code->Chat->CoWork) it acts during
    // the unsettled transition; AXDriver.find's first-DFS-match can grab a transient
    // / non-visible composer, so setValue lands off the visible composer and the turn
    // never starts. The settled CoWork composer is always [focused] + on-screen, so
    // prefer a focused match, then an on-screen one, then fall back to the first.

    func testPrefersFocusedOverNonFocused() {
        let c = [
            ComposerCandidate(focused: false, onScreen: true),  // transient / stale
            ComposerCandidate(focused: true, onScreen: true),   // the settled, visible composer
        ]
        XCTAssertEqual(selectComposerIndex(c), 1)
    }

    func testFocusedWinsRegardlessOfOrder() {
        let c = [
            ComposerCandidate(focused: true, onScreen: true),
            ComposerCandidate(focused: false, onScreen: true),
        ]
        XCTAssertEqual(selectComposerIndex(c), 0)
    }

    func testFocusedWinsEvenIfNotOnScreen() {
        // Focused is the reliable signal; a focused element is the active composer.
        let c = [
            ComposerCandidate(focused: false, onScreen: true),
            ComposerCandidate(focused: true, onScreen: false),
        ]
        XCTAssertEqual(selectComposerIndex(c), 1)
    }

    func testFallsBackToFirstOnScreenWhenNoneFocused() {
        let c = [
            ComposerCandidate(focused: false, onScreen: false),
            ComposerCandidate(focused: false, onScreen: true),
        ]
        XCTAssertEqual(selectComposerIndex(c), 1)
    }

    func testFallsBackToFirstWhenNoneFocusedOrOnScreen() {
        let c = [
            ComposerCandidate(focused: false, onScreen: false),
            ComposerCandidate(focused: false, onScreen: false),
        ]
        XCTAssertEqual(selectComposerIndex(c), 0)
    }

    func testSingleCandidate() {
        XCTAssertEqual(selectComposerIndex([ComposerCandidate(focused: true, onScreen: true)]), 0)
    }

    func testNilWhenEmpty() {
        XCTAssertNil(selectComposerIndex([]))
    }
}
