// SPDX-License-Identifier: MIT
import Foundation

/// One turn of a recording: drive `command` on `surface`, optionally prefixing
/// the composer text with `systemPromptPrologue`. A multi-surface recording is an
/// ordered list of these (rr-u07); a legacy single-surface spec collapses to one
/// Step per command (all sharing the spec's surface; prologue on the first only).
public struct Step: Equatable {
    public let surface: String
    public let command: String
    public let systemPromptPrologue: String?

    public init(surface: String, command: String, systemPromptPrologue: String? = nil) {
        self.surface = surface
        self.command = command
        self.systemPromptPrologue = systemPromptPrologue
    }
}

/// The slice of a recording spec the driver needs: the ordered surface/command
/// steps to drive and the deterministic recording geometry. Parsing is pure
/// (Foundation `JSONSerialization`) so it is unit-tested without a live app; the
/// executable feeds `steps` into the AX-drive sequence.
public struct DriverSpec: Equatable {
    /// Ordered turns to drive. Always non-empty. For a single-surface spec this is
    /// synthesized from `surface` + `commands` (one Step each); for a `steps[]`
    /// spec it is parsed directly. The driver iterates this uniformly.
    public let steps: [Step]
    /// Back-compat projection of the first step's surface (legacy single-surface
    /// callers). For a `steps[]` spec this is `steps[0].surface`.
    public let surface: String
    /// Back-compat projection of every step's command, in order.
    public let commands: [String]
    public let recordingSize: Size
    /// Back-compat projection of the first step's prologue. Claude.app Chat has no
    /// system-prompt CLI flag, so the prologue (which tells the model to call
    /// rig_checkpoint / rig_turn_end) is delivered as part of the composer text.
    public let systemPromptPrologue: String?

    public init(steps: [Step], recordingSize: Size) {
        self.steps = steps
        self.surface = steps.first?.surface ?? "chat"
        self.commands = steps.map { $0.command }
        self.systemPromptPrologue = steps.first?.systemPromptPrologue
        self.recordingSize = recordingSize
    }

    /// Legacy initializer (single-surface): synthesizes one Step per command, the
    /// prologue on the first only. Retained so existing callers/tests construct the
    /// same shape the parser now produces.
    public init(surface: String, commands: [String], recordingSize: Size, systemPromptPrologue: String? = nil) {
        let steps = commands.enumerated().map { i, c in
            Step(surface: surface, command: c, systemPromptPrologue: i == 0 ? systemPromptPrologue : nil)
        }
        self.init(steps: steps, recordingSize: recordingSize)
    }
}

public enum SpecReader {
    /// Parse a spec. `surface` defaults to "chat"; `commands` mirrors
    /// bin/driver.sh:43-52 (agent.commands[] wins, else [agent.command], else
    /// fail loud); `recordingSize` comes from `pacing.tmux_size` ("WxH"),
    /// default 1280x800 (RDR-001 §Technical Design geometry).
    public static func parse(_ data: Data) throws -> DriverSpec {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DriverError.badConfig("spec is not a JSON object")
        }

        let size = parseSize(obj)

        // Multi-surface form (rr-u07): an explicit top-level `steps[]` supersedes
        // the single-surface fields. Present-but-malformed fails loud rather than
        // silently falling back to the single-surface path.
        if obj["steps"] != nil {
            guard let rawSteps = obj["steps"] as? [[String: Any]], !rawSteps.isEmpty else {
                throw DriverError.badConfig("steps must be a non-empty array of {surface, command} objects")
            }
            let steps = try rawSteps.map { raw -> Step in
                guard let cmd = raw["command"] as? String, !cmd.isEmpty else {
                    throw DriverError.badConfig("steps[] entry missing a non-empty command")
                }
                let surface = (raw["surface"] as? String) ?? "chat"
                let prologue = (raw["system_prompt_prologue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return Step(surface: surface, command: cmd, systemPromptPrologue: prologue)
            }
            return DriverSpec(steps: steps, recordingSize: size)
        }

        // Single-surface form (legacy): surface + agent.command(s). `commands[]`
        // mirrors bin/driver.sh:43-52 (agent.commands[] wins, else [agent.command],
        // else fail loud); synthesized into one Step per command (prologue on first).
        let surface = (obj["surface"] as? String) ?? "chat"
        var commands: [String] = []
        if let agent = obj["agent"] as? [String: Any] {
            if let arr = agent["commands"] as? [String], !arr.isEmpty {
                commands = arr.filter { !$0.isEmpty }
            } else if let cmd = agent["command"] as? String, !cmd.isEmpty {
                commands = [cmd]
            }
        }
        guard !commands.isEmpty else {
            throw DriverError.badConfig("spec has no agent.command or agent.commands")
        }
        let prologue = (obj["system_prompt_prologue"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return DriverSpec(surface: surface, commands: commands, recordingSize: size, systemPromptPrologue: prologue)
    }

    /// `pacing.tmux_size` ("WxH") reused as the recording geometry; default
    /// 1280x800 (RDR-001 §Technical Design) on absence or malformed input.
    private static func parseSize(_ obj: [String: Any]) -> Size {
        guard let pacing = obj["pacing"] as? [String: Any],
              let dims = pacing["tmux_size"] as? String else {
            return Size(width: 1280, height: 800)
        }
        let parts = dims.lowercased().split(separator: "x")
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
            return Size(width: w, height: h)
        }
        return Size(width: 1280, height: 800)
    }

    public static func load(path: String) throws -> DriverSpec {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw DriverError.badConfig("spec file not found: \(path)")
        }
        return try parse(data)
    }
}
