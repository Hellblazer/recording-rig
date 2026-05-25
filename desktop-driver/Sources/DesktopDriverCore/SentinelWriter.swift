// SPDX-License-Identifier: MIT
import Foundation

/// Writes sentinel files under `<directory>/<session>.<suffix>` using the
/// byte-identical contract of the CLI rig and the bridge: write a `.partial`
/// sibling, then `rename(2)` it onto the final path (atomic on the same APFS
/// volume — `/tmp` qualifies, RDR 001-research-5). Markers carry empty content
/// (byte-identical to the CLI hooks' `touch`); content sentinels carry NO
/// trailing newline. Ports bin/render-hooks.sh:31-44 + bridge/server.js:46-58.
///
/// The driver writes exactly one sentinel — `prompt-submitted` — but the writer
/// is general so the contract lives in one tested place.
public struct SentinelWriter {
    public let directory: String
    public let session: String

    public init(directory: String, session: String) {
        self.directory = directory
        self.session = session
    }

    public func path(_ suffix: String) -> String {
        "\(directory)/\(session).\(suffix)"
    }

    /// Atomic write. `content` is written verbatim — no trailing newline is
    /// appended. Pass "" for a marker sentinel.
    public func write(suffix: String, content: String) throws {
        let finalPath = path(suffix)
        let partialPath = finalPath + ".partial"
        do {
            try content.write(toFile: partialPath, atomically: false, encoding: .utf8)
        } catch {
            throw DriverError.sentinelWrite("partial write failed for \(partialPath): \(error)")
        }
        if rename(partialPath, finalPath) != 0 {
            let err = String(cString: strerror(errno))
            // Best-effort cleanup of the orphaned partial; the failure is the story.
            try? FileManager.default.removeItem(atPath: partialPath)
            throw DriverError.sentinelWrite("rename \(partialPath) -> \(finalPath) failed: \(err)")
        }
    }

    /// Write a 0-byte marker sentinel (e.g. `prompt-submitted`).
    public func writeMarker(_ suffix: String) throws {
        try write(suffix: suffix, content: "")
    }
}
