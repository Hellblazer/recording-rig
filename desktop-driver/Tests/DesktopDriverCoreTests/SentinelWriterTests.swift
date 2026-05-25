// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class SentinelWriterTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "rigdrv-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testMarkerIsZeroBytes() throws {
        let w = SentinelWriter(directory: dir, session: "sess")
        try w.writeMarker("prompt-submitted")
        let p = dir + "/sess.prompt-submitted"
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        let data = try Data(contentsOf: URL(fileURLWithPath: p))
        XCTAssertEqual(data.count, 0, "marker is byte-identical to touch (0 bytes)")
    }

    func testContentHasNoTrailingNewline() throws {
        let w = SentinelWriter(directory: dir, session: "sess")
        try w.write(suffix: "answer", content: "{\"v\":42}")
        let body = try String(contentsOfFile: dir + "/sess.answer", encoding: .utf8)
        XCTAssertEqual(body, "{\"v\":42}")
        XCTAssertFalse(body.hasSuffix("\n"), "sentinel carries no trailing newline")
    }

    func testNoPartialLeftBehind() throws {
        let w = SentinelWriter(directory: dir, session: "sess")
        try w.writeMarker("prompt-submitted")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir + "/sess.prompt-submitted.partial"),
            "the .partial sibling is consumed by rename(2)"
        )
    }

    func testPathComposition() {
        let w = SentinelWriter(directory: "/tmp", session: "gate-smoke")
        XCTAssertEqual(w.path("prompt-submitted"), "/tmp/gate-smoke.prompt-submitted")
    }
}
