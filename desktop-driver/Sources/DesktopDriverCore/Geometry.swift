// SPDX-License-Identifier: MIT
import Foundation

/// A window size, kept framework-free (no CGSize) so the core stays pure.
public struct Size: Equatable, Codable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// The deterministic recording geometry can revert after an AX set, so the
/// driver re-asserts (RDR-001 §Technical Design, "verify + re-assert"). This is
/// the pure decision: re-assert when the current size is unknown or has drifted.
public func sizeNeedsReassert(current: Size?, target: Size) -> Bool {
    guard let current else { return true }
    return current != target
}
