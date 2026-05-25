// SPDX-License-Identifier: MIT
import Foundation

/// One AX element locator: a role (e.g. "AXButton", "AXTextArea") plus the
/// `AXDescription` to match. Externalized to bin/desktop-ax-selectors.json
/// (RDR-001 §Technical Design L535) so selector drift doesn't require a rebuild.
public struct Selector: Equatable, Codable {
    public let role: String
    public let axDescription: String

    public init(role: String, axDescription: String) {
        self.role = role
        self.axDescription = axDescription
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case axDescription = "description"
    }
}

/// The locators for one surface (Chat / Code / CoWork): the tab button to press
/// and the composer text area to set + submit into.
public struct SurfaceSelectors: Equatable, Codable {
    public let navButton: Selector
    public let composer: Selector
}

/// Top-level selectors file: surface name -> its locators.
public struct Selectors: Equatable, Codable {
    public let surfaces: [String: SurfaceSelectors]

    /// Look up one surface's selectors, failing loud on an unknown surface
    /// rather than silently driving the wrong element.
    public func surface(_ name: String) throws -> SurfaceSelectors {
        guard let s = surfaces[name] else {
            throw DriverError.badSelectors("no selectors for surface '\(name)'")
        }
        return s
    }

    /// Decode the selectors JSON, wrapping any parse failure as a loud
    /// `badSelectors` (a malformed file must abort, not yield empty locators).
    public static func decode(_ data: Data) throws -> Selectors {
        do {
            return try JSONDecoder().decode(Selectors.self, from: data)
        } catch {
            throw DriverError.badSelectors("malformed selectors JSON: \(error)")
        }
    }

    public static func load(path: String) throws -> Selectors {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw DriverError.badSelectors("selectors file not found: \(path)")
        }
        return try decode(data)
    }
}
