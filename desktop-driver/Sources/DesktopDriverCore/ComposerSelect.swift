// SPDX-License-Identifier: MIT
import Foundation

/// A framework-free descriptor of a composer (AXTextArea) candidate — enough to
/// choose the right one without depending on ApplicationServices, so the choice is
/// unit-testable. `focused` is the element's kAXFocused; `onScreen` is whether its
/// frame is a real, on-screen, non-zero region.
public struct ComposerCandidate: Equatable {
    public let focused: Bool
    public let onScreen: Bool
    public init(focused: Bool, onScreen: Bool) {
        self.focused = focused
        self.onScreen = onScreen
    }
}

/// Choose which composer to drive among several role+description matches.
///
/// rr-bw3: driving a surface as a LATER multi-surface step (e.g. CoWork after
/// Code→Chat) acts during the unsettled surface transition, where AXDriver.find's
/// first-DFS-match can return a transient / non-visible composer. setValue then
/// lands off the visible composer and the turn never starts (empty composer, rc=3).
/// The settled, visible composer is always [focused] and on-screen, so:
///   1. prefer a focused candidate (the active composer),
///   2. else the first on-screen candidate,
///   3. else the first candidate (preserve the original first-match behavior).
/// Returns nil only when there are no candidates.
public func selectComposerIndex(_ candidates: [ComposerCandidate]) -> Int? {
    if let i = candidates.firstIndex(where: { $0.focused }) { return i }
    if let i = candidates.firstIndex(where: { $0.onScreen }) { return i }
    return candidates.isEmpty ? nil : 0
}
