// SPDX-License-Identifier: MIT
import Foundation

/// Parsed launch configuration for `bin/desktop-driver`.
///
/// `record.sh` (rr-2pp.3.3) resolves the Claude-Rig PID, exports `SESSION`, and
/// execs the driver: `desktop-driver --pid <pid> --spec <path> [--session <id>]`.
/// SESSION is taken from `--session` if present, else the `SESSION` env var
/// (mirroring the CLI rig, which `export`s it). The driver writes exactly one
/// sentinel — `<tmpRoot>/<session>.prompt-submitted` — so it resolves the same
/// `RIG_TMP`-overridable root the bridge uses (default `/tmp`), keeping the
/// sentinel namespace identical and the path test-injectable.
public struct DriverConfig: Equatable {
    public let rigPid: Int32
    public let session: String
    public let specPath: String
    public let tmpRoot: String

    /// Same identifier guard as the bridge / lib/sentinels.sh:12. The session
    /// becomes a path suffix, so an invalid value must fail loud, not escape.
    static func isValidSession(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            let ok = (scalar >= "A" && scalar <= "Z")
                || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "_" || scalar == "-"
            if !ok { return false }
        }
        return true
    }

    /// Parse argv + environment. Fails loud (`badConfig`) on a missing/invalid
    /// pid, a missing/invalid session, or a missing spec path.
    public static func parse(arguments: [String], environment: [String: String]) throws -> DriverConfig {
        var pidArg: String?
        var sessionArg: String?
        var specArg: String?

        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--pid":
                pidArg = valueAfter(arguments, &i, flag: a)
            case "--session":
                sessionArg = valueAfter(arguments, &i, flag: a)
            case "--spec":
                specArg = valueAfter(arguments, &i, flag: a)
            default:
                // First bare token is treated as the spec path (positional).
                if specArg == nil, !a.hasPrefix("--") { specArg = a }
            }
            i += 1
        }

        guard let pidArg else { throw DriverError.badConfig("missing --pid") }
        guard let rigPid = Int32(pidArg), rigPid > 0 else {
            throw DriverError.badConfig("invalid --pid: \(pidArg)")
        }

        let session = sessionArg ?? environment["SESSION"] ?? ""
        guard isValidSession(session) else {
            throw DriverError.badConfig("invalid session (must match ^[A-Za-z0-9._-]+$): '\(session)'")
        }

        guard let specArg, !specArg.isEmpty else {
            throw DriverError.badConfig("missing --spec / spec path")
        }

        let tmpRoot = environment["RIG_TMP"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return DriverConfig(rigPid: rigPid, session: session, specPath: specArg, tmpRoot: tmpRoot)
    }

    private static func valueAfter(_ args: [String], _ i: inout Int, flag: String) -> String? {
        guard i + 1 < args.count else { return nil }
        i += 1
        return args[i]
    }
}
