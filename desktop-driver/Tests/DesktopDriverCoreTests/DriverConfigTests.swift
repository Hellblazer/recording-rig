// SPDX-License-Identifier: MIT
import XCTest
@testable import DesktopDriverCore

final class DriverConfigTests: XCTestCase {
    func testParsesFlags() throws {
        let c = try DriverConfig.parse(
            arguments: ["desktop-driver", "--pid", "4321", "--session", "rig-x", "--spec", "/tmp/spec.json"],
            environment: [:]
        )
        XCTAssertEqual(c.rigPid, 4321)
        XCTAssertEqual(c.session, "rig-x")
        XCTAssertEqual(c.specPath, "/tmp/spec.json")
        XCTAssertEqual(c.tmpRoot, "/tmp", "tmpRoot defaults to /tmp when RIG_TMP unset")
    }

    func testSessionFallsBackToEnv() throws {
        let c = try DriverConfig.parse(
            arguments: ["desktop-driver", "--pid", "1", "--spec", "/s.json"],
            environment: ["SESSION": "from-env"]
        )
        XCTAssertEqual(c.session, "from-env")
    }

    func testRigTmpOverride() throws {
        let c = try DriverConfig.parse(
            arguments: ["desktop-driver", "--pid", "1", "--session", "s", "--spec", "/s.json"],
            environment: ["RIG_TMP": "/var/folders/x"]
        )
        XCTAssertEqual(c.tmpRoot, "/var/folders/x")
    }

    func testPositionalSpec() throws {
        let c = try DriverConfig.parse(
            arguments: ["desktop-driver", "--pid", "9", "--session", "s", "/positional/spec.json"],
            environment: [:]
        )
        XCTAssertEqual(c.specPath, "/positional/spec.json")
    }

    func testMissingPidFailsLoud() {
        XCTAssertThrowsError(
            try DriverConfig.parse(arguments: ["desktop-driver", "--session", "s", "--spec", "/s"], environment: [:])
        ) { XCTAssertEqual($0 as? DriverError, .badConfig("missing --pid")) }
    }

    func testInvalidPidFailsLoud() {
        XCTAssertThrowsError(
            try DriverConfig.parse(arguments: ["desktop-driver", "--pid", "0", "--session", "s", "--spec", "/s"], environment: [:])
        )
        XCTAssertThrowsError(
            try DriverConfig.parse(arguments: ["desktop-driver", "--pid", "notanum", "--session", "s", "--spec", "/s"], environment: [:])
        )
    }

    func testInvalidSessionFailsLoud() {
        // Space + slash escape the /tmp/<session>.* namespace — must be rejected.
        XCTAssertThrowsError(
            try DriverConfig.parse(arguments: ["desktop-driver", "--pid", "1", "--session", "bad sess", "--spec", "/s"], environment: [:])
        )
        XCTAssertThrowsError(
            try DriverConfig.parse(arguments: ["desktop-driver", "--pid", "1", "--session", "../escape", "--spec", "/s"], environment: [:])
        )
        XCTAssertThrowsError(
            try DriverConfig.parse(arguments: ["desktop-driver", "--pid", "1", "--spec", "/s"], environment: [:])
        ) { XCTAssertTrue("\($0)".contains("session")) }
    }

    func testPidAsTrailingFlagOrFollowedByFlagFailsLoud() {
        // --pid is the final token (no value).
        XCTAssertThrowsError(
            try DriverConfig.parse(arguments: ["desktop-driver", "--pid"], environment: [:])
        ) { XCTAssertEqual($0 as? DriverError, .badConfig("missing --pid")) }
        // --pid immediately followed by another flag must not swallow it as the value.
        XCTAssertThrowsError(
            try DriverConfig.parse(
                arguments: ["desktop-driver", "--pid", "--session", "s", "--spec", "/s"],
                environment: [:])
        ) { XCTAssertEqual($0 as? DriverError, .badConfig("missing --pid")) }
    }

    func testDuplicateFlagLastWins() throws {
        // Documents the behavior: last value wins (record.sh never emits dupes).
        let c = try DriverConfig.parse(
            arguments: ["desktop-driver", "--pid", "100", "--pid", "200", "--session", "s", "--spec", "/s"],
            environment: [:]
        )
        XCTAssertEqual(c.rigPid, 200)
    }

    func testMissingSpecFailsLoud() {
        XCTAssertThrowsError(
            try DriverConfig.parse(arguments: ["desktop-driver", "--pid", "1", "--session", "s"], environment: [:])
        ) { XCTAssertEqual($0 as? DriverError, .badConfig("missing --spec / spec path")) }
    }

    func testValidSessionCharset() {
        XCTAssertTrue(DriverConfig.isValidSession("rig.example_desktop-chat-01"))
        XCTAssertFalse(DriverConfig.isValidSession(""))
        XCTAssertFalse(DriverConfig.isValidSession("has space"))
        XCTAssertFalse(DriverConfig.isValidSession("has/slash"))
    }
}
