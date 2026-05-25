// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class SelectorsTests: XCTestCase {
    func testDecodesChatSelectors() throws {
        let json = """
        { "surfaces": {
            "chat": {
              "navButton": { "role": "AXButton", "description": "Chat" },
              "composer": { "role": "AXTextArea", "description": "Write your prompt to Claude" }
            }
        } }
        """
        let s = try Selectors.decode(Data(json.utf8))
        let chat = try s.surface("chat")
        XCTAssertEqual(chat.navButton, Selector(role: "AXButton", axDescription: "Chat"))
        XCTAssertEqual(chat.composer.axDescription, "Write your prompt to Claude")
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

    func testRepoSelectorsFileMatchesValidatedChatDescriptions() throws {
        // The committed bin/desktop-ax-selectors.json must carry the Phase-0
        // validated Chat composer description verbatim (T2 …-ax-input-submit-…).
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let selPath = repoRoot.appendingPathComponent("bin/desktop-ax-selectors.json").path
        let s = try Selectors.load(path: selPath)
        let chat = try s.surface("chat")
        XCTAssertEqual(chat.composer.axDescription, "Write your prompt to Claude")
        XCTAssertEqual(chat.navButton.role, "AXButton")
    }

    func testRepoSelectorsFileHasCodeAndCoworkSurfaces() throws {
        // Phase 4 Step 1 (rr-2pp.5.1): the committed file must carry the live-
        // observed Code + CoWork locators (ax-dump against Claude-Rig, 2026-05-25;
        // T2 recording-rig/scratch). Code's composer description ("Prompt")
        // DIFFERS from Chat/CoWork ("Write your prompt to Claude") — that
        // divergence is the whole reason this surface needed live discovery.
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let selPath = repoRoot.appendingPathComponent("bin/desktop-ax-selectors.json").path
        let s = try Selectors.load(path: selPath)

        let code = try s.surface("code")
        XCTAssertEqual(code.navButton, Selector(role: "AXButton", axDescription: "Code"))
        XCTAssertEqual(code.composer, Selector(role: "AXTextArea", axDescription: "Prompt"))

        let cowork = try s.surface("cowork")
        XCTAssertEqual(cowork.navButton, Selector(role: "AXButton", axDescription: "Cowork"))
        XCTAssertEqual(cowork.composer, Selector(role: "AXTextArea", axDescription: "Write your prompt to Claude"))
    }
}
