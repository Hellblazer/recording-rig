// SPDX-License-Identifier: MIT
import Foundation

/// The slice of a recording spec the driver needs: which surface to drive,
/// the command(s) to paste, and the deterministic recording geometry. Parsing
/// is pure (Foundation `JSONSerialization`) so it is unit-tested without a live
/// app; the executable feeds the result into the AX-drive sequence.
public struct DriverSpec: Equatable {
    public let surface: String
    public let commands: [String]
    public let recordingSize: Size
    /// Instruction prologue prepended to the first pasted command. Claude.app
    /// Chat has no system-prompt CLI flag, so the prologue (which tells the
    /// model to call rig_checkpoint / rig_turn_end) is delivered as part of the
    /// composer text. nil/empty when the spec omits it.
    public let systemPromptPrologue: String?

    public init(surface: String, commands: [String], recordingSize: Size, systemPromptPrologue: String? = nil) {
        self.surface = surface
        self.commands = commands
        self.recordingSize = recordingSize
        self.systemPromptPrologue = systemPromptPrologue
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

        var size = Size(width: 1280, height: 800)
        if let pacing = obj["pacing"] as? [String: Any],
           let dims = pacing["tmux_size"] as? String {
            let parts = dims.lowercased().split(separator: "x")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                size = Size(width: w, height: h)
            }
        }

        let prologue = (obj["system_prompt_prologue"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return DriverSpec(surface: surface, commands: commands, recordingSize: size, systemPromptPrologue: prologue)
    }

    public static func load(path: String) throws -> DriverSpec {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw DriverError.badConfig("spec file not found: \(path)")
        }
        return try parse(data)
    }
}
