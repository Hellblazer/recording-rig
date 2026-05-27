// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class SpecReaderTests: XCTestCase {
    private func spec(_ json: String) throws -> DriverSpec {
        try SpecReader.parse(Data(json.utf8))
    }

    func testSingleCommandAndDefaults() throws {
        let s = try spec(#"{ "agent": { "command": "/do-thing" } }"#)
        XCTAssertEqual(s.commands, ["/do-thing"])
        XCTAssertEqual(s.surface, "chat", "surface defaults to chat")
        XCTAssertEqual(s.recordingSize, Size(width: 1280, height: 800), "default geometry")
    }

    func testCommandsArrayWins() throws {
        let s = try spec(#"{ "agent": { "command": "ignored", "commands": ["a", "b"] } }"#)
        XCTAssertEqual(s.commands, ["a", "b"])
    }

    func testSurfaceAndPacingSize() throws {
        let s = try spec(#"{ "surface": "code", "agent": { "command": "x" }, "pacing": { "tmux_size": "1920x1080" } }"#)
        XCTAssertEqual(s.surface, "code")
        XCTAssertEqual(s.recordingSize, Size(width: 1920, height: 1080))
    }

    func testMalformedPacingSizeFallsBackToDefault() throws {
        let s = try spec(#"{ "agent": { "command": "x" }, "pacing": { "tmux_size": "garbage" } }"#)
        XCTAssertEqual(s.recordingSize, Size(width: 1280, height: 800))
    }

    func testNoCommandFailsLoud() {
        XCTAssertThrowsError(try spec(#"{ "agent": {} }"#)) {
            XCTAssertEqual($0 as? DriverError, .badConfig("spec has no agent.command or agent.commands"))
        }
        XCTAssertThrowsError(try spec(#"{ "surface": "chat" }"#))
    }

    func testEmptyCommandsArrayFallsBackToCommand() throws {
        let s = try spec(#"{ "agent": { "command": "c", "commands": [] } }"#)
        XCTAssertEqual(s.commands, ["c"], "empty commands[] falls back to command")
    }

    func testSystemPromptPrologueParsed() throws {
        let s = try spec(#"{ "agent": { "command": "hi" }, "system_prompt_prologue": "call rig_turn_end" }"#)
        XCTAssertEqual(s.systemPromptPrologue, "call rig_turn_end")
    }

    func testSystemPromptPrologueNilWhenAbsentOrEmpty() throws {
        XCTAssertNil(try spec(#"{ "agent": { "command": "hi" } }"#).systemPromptPrologue)
        XCTAssertNil(try spec(#"{ "agent": { "command": "hi" }, "system_prompt_prologue": "" }"#).systemPromptPrologue)
    }

    func testNonObjectFailsLoud() {
        XCTAssertThrowsError(try spec("[1,2,3]")) {
            XCTAssertEqual($0 as? DriverError, .badConfig("spec is not a JSON object"))
        }
    }

    // --- rr-7ib: multi-surface steps[] ---

    func testStepsArrayParsedMultiSurface() throws {
        let s = try spec(#"""
        { "steps": [
            { "surface": "code", "command": "write the file", "system_prompt_prologue": "load tools" },
            { "surface": "chat", "command": "narrate it" },
            { "surface": "cowork", "command": "read it back" }
        ] }
        """#)
        XCTAssertEqual(s.steps.count, 3)
        XCTAssertEqual(s.steps[0], Step(surface: "code", command: "write the file", systemPromptPrologue: "load tools"))
        XCTAssertEqual(s.steps[1], Step(surface: "chat", command: "narrate it", systemPromptPrologue: nil))
        XCTAssertEqual(s.steps[2], Step(surface: "cowork", command: "read it back", systemPromptPrologue: nil))
    }

    func testStepsArrayProjectsBackCompatFields() throws {
        // The legacy surface / commands / prologue fields mirror the first step
        // and the flattened command list, so code reading the old fields still works.
        let s = try spec(#"{ "steps": [ { "surface": "code", "command": "a", "system_prompt_prologue": "p" }, { "surface": "chat", "command": "b" } ] }"#)
        XCTAssertEqual(s.surface, "code")
        XCTAssertEqual(s.commands, ["a", "b"])
        XCTAssertEqual(s.systemPromptPrologue, "p")
    }

    func testStepSurfaceDefaultsToChat() throws {
        let s = try spec(#"{ "steps": [ { "command": "x" } ] }"#)
        XCTAssertEqual(s.steps[0].surface, "chat")
    }

    func testStepMissingCommandFailsLoud() {
        XCTAssertThrowsError(try spec(#"{ "steps": [ { "surface": "code" } ] }"#)) {
            XCTAssertEqual($0 as? DriverError, .badConfig("steps[] entry missing a non-empty command"))
        }
    }

    func testEmptyStepsArrayFailsLoud() {
        XCTAssertThrowsError(try spec(#"{ "steps": [] }"#)) {
            XCTAssertEqual($0 as? DriverError, .badConfig("steps must be a non-empty array of {surface, command} objects"))
        }
    }

    func testStepsNotArrayFailsLoud() {
        XCTAssertThrowsError(try spec(#"{ "steps": "nope" }"#)) {
            XCTAssertEqual($0 as? DriverError, .badConfig("steps must be a non-empty array of {surface, command} objects"))
        }
    }

    func testSingleSurfaceSpecSynthesizesSteps() throws {
        // Back-compat: a legacy spec yields a steps[] of one Step per command, the
        // prologue on the first step only, all sharing the spec's surface.
        let s = try spec(#"{ "surface": "code", "agent": { "commands": ["a", "b"] }, "system_prompt_prologue": "p" }"#)
        XCTAssertEqual(s.steps, [
            Step(surface: "code", command: "a", systemPromptPrologue: "p"),
            Step(surface: "code", command: "b", systemPromptPrologue: nil),
        ])
    }
}
