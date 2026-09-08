// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class SelectorsTests: XCTestCase {
    private func repoSelectors() throws -> Selectors {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Selectors.load(path: repoRoot.appendingPathComponent("bin/desktop-ax-selectors.json").path)
    }

    func testDecodesNavSequenceWithDescriptionAndTitleSelectors() throws {
        let json = """
        { "surfaces": {
            "chat": {
              "nav": [
                { "role": "AXRadioButton", "description": "Chat and Cowork" },
                { "role": "AXRadioButton", "title": "Chat" }
              ],
              "composer": { "role": "AXTextArea", "description": "Write your prompt to Claude" }
            }
        } }
        """
        let chat = try Selectors.decode(Data(json.utf8)).surface("chat")
        XCTAssertEqual(chat.nav, [
            Selector(role: "AXRadioButton", axDescription: "Chat and Cowork"),
            Selector(role: "AXRadioButton", title: "Chat"),
        ])
        XCTAssertEqual(chat.composer.axDescription, "Write your prompt to Claude")
    }

    func testLegacyNavButtonDecodesAsOneElementNav() throws {
        // Pre-rr-ay1 selectors files carry a single `navButton`; they must keep
        // decoding so an older selectors file never silently loses its nav.
        let json = """
        { "surfaces": {
            "chat": {
              "navButton": { "role": "AXButton", "description": "Chat" },
              "composer": { "role": "AXTextArea", "description": "Write your prompt to Claude" }
            }
        } }
        """
        let chat = try Selectors.decode(Data(json.utf8)).surface("chat")
        XCTAssertEqual(chat.nav, [Selector(role: "AXButton", axDescription: "Chat")])
    }

    func testSelectorWithNeitherDescriptionNorTitleFailsLoud() {
        let json = """
        { "surfaces": { "chat": {
            "nav": [ { "role": "AXRadioButton" } ],
            "composer": { "role": "AXTextArea", "description": "x" }
        } } }
        """
        XCTAssertThrowsError(try Selectors.decode(Data(json.utf8))) {
            guard case DriverError.badSelectors(let msg) = $0 else {
                return XCTFail("expected badSelectors, got \($0)")
            }
            XCTAssertTrue(msg.contains("description or a title"), msg)
        }
    }

    func testEmptyNavFailsLoud() {
        let json = """
        { "surfaces": { "chat": {
            "nav": [],
            "composer": { "role": "AXTextArea", "description": "x" }
        } } }
        """
        XCTAssertThrowsError(try Selectors.decode(Data(json.utf8))) {
            guard case DriverError.badSelectors = $0 else {
                return XCTFail("expected badSelectors, got \($0)")
            }
        }
    }

    func testMatchesRequiresEveryGivenAttribute() {
        let byDesc = Selector(role: "AXRadioButton", axDescription: "Code")
        XCTAssertTrue(byDesc.matches(role: "AXRadioButton", description: "Code", title: nil))
        XCTAssertFalse(byDesc.matches(role: "AXButton", description: "Code", title: nil))
        XCTAssertFalse(byDesc.matches(role: "AXRadioButton", description: nil, title: "Code"))

        let byTitle = Selector(role: "AXRadioButton", title: "Chat")
        XCTAssertTrue(byTitle.matches(role: "AXRadioButton", description: nil, title: "Chat"))
        XCTAssertFalse(byTitle.matches(role: "AXRadioButton", description: "Chat", title: nil))

        let both = Selector(role: "AXRadioButton", axDescription: "Surface", title: "Chat")
        XCTAssertTrue(both.matches(role: "AXRadioButton", description: "Surface", title: "Chat"))
        XCTAssertFalse(both.matches(role: "AXRadioButton", description: "Surface", title: "Cowork"))
    }

    func testUnknownSurfaceFailsLoud() throws {
        let s = try Selectors.decode(Data("{ \"surfaces\": {} }".utf8))
        XCTAssertThrowsError(try s.surface("code")) {
            XCTAssertEqual($0 as? DriverError, .badSelectors("no selectors for surface 'code'"))
        }
    }

    func testMalformedJSONFailsLoud() {
        XCTAssertThrowsError(try Selectors.decode(Data("not json{".utf8))) {
            guard case DriverError.badSelectors = $0 else {
                return XCTFail("expected badSelectors, got \($0)")
            }
        }
    }

    func testRepoSelectorsFileMatchesLiveClaudeApp146388() throws {
        // The committed bin/desktop-ax-selectors.json must carry the locators
        // observed live on Claude.app 1.46388.4 (ax-dump against Claude-Rig,
        // 2026-09-08, rr-ay1): the surface switch is two radio groups — the
        // top-left mode radio ("Chat and Cowork" | "Code", AXDescription) and
        // the composer's "Surface" radio group ("Chat" | "Cowork", AXTitle only).
        let s = try repoSelectors()
        let mode = Selector(role: "AXRadioButton", axDescription: "Chat and Cowork")

        let chat = try s.surface("chat")
        XCTAssertEqual(chat.nav, [mode, Selector(role: "AXRadioButton", title: "Chat")])
        XCTAssertEqual(chat.composer, Selector(role: "AXTextArea", axDescription: "Write your prompt to Claude"))

        let cowork = try s.surface("cowork")
        XCTAssertEqual(cowork.nav, [mode, Selector(role: "AXRadioButton", title: "Cowork")])
        XCTAssertEqual(cowork.composer, Selector(role: "AXTextArea", axDescription: "Write your prompt to Claude"))

        let code = try s.surface("code")
        XCTAssertEqual(code.nav, [Selector(role: "AXRadioButton", axDescription: "Code")])
        XCTAssertEqual(code.composer.role, "AXTextArea")
    }
}
