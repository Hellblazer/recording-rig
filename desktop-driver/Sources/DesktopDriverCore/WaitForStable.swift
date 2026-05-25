// SPDX-License-Identifier: MIT
import Foundation

/// The `armWait` core (RDR-001 driver INVARIANT 1): a11y collapses across UI
/// re-renders, so before EVERY action the driver re-arms `AXManualAccessibility`
/// and polls until the target element re-appears, failing loud on timeout —
/// never caching an element handle across renders.
///
/// This type is the pure, hermetic heart of that loop. The clock and sleep are
/// injectable so the success-after-N-polls and timeout branches are unit-tested
/// without real time; the live AX walk is supplied as the `rearm` + `probe`
/// closures by the executable target.
public struct WaitForStable {
    private let now: () -> Double
    private let sleep: (Double) -> Void

    public init(
        now: @escaping () -> Double = { Date().timeIntervalSince1970 },
        sleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Re-arm then probe, repeating every `poll` seconds until `probe` returns a
    /// value or `timeout` seconds elapse (then throw `.timeout`). `rearm` runs
    /// before each probe (re-set `AXManualAccessibility` in the live path).
    ///
    /// `timeout` must be positive. The element is always probed at least once
    /// (before the deadline check), so `timeout <= 0` means "probe exactly once,
    /// then throw if absent" — NOT an infinite wait.
    public func wait<T>(
        label: String,
        timeout: Double,
        poll: Double,
        rearm: () -> Void = {},
        _ probe: () -> T?
    ) throws -> T {
        let start = now()
        while true {
            rearm()
            if let value = probe() {
                return value
            }
            if now() - start >= timeout {
                throw DriverError.timeout("armWait timed out after \(timeout)s waiting for \(label)")
            }
            sleep(poll)
        }
    }
}
