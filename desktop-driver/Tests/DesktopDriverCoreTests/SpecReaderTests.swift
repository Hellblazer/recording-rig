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
}
