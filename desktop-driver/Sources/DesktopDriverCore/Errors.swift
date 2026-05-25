// SPDX-License-Identifier: MIT
import Foundation

/// Errors raised by the pure driver core. All fail loud (RDR-001 driver
/// invariants): a swallowed AX/config failure produces an empty tree or a
/// silently mis-targeted action, so every failure path surfaces here.
public enum DriverError: Error, Equatable {
    /// `armWait` exhausted its timeout without the element appearing.
    case timeout(String)
    /// argv/env did not yield a usable rigPid / session / spec.
    case badConfig(String)
    /// the AX selectors JSON was missing or malformed.
    case badSelectors(String)
    /// an atomic sentinel write failed (partial write or rename(2)).
    case sentinelWrite(String)
}
