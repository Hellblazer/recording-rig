// SPDX-License-Identifier: MIT
import Foundation

/// One AX element locator: a role (e.g. "AXButton", "AXTextArea") plus the
/// `AXDescription` and/or `AXTitle` to match. At least one of the two text
/// attributes must be given; when both are, both must match. Externalized to
/// bin/desktop-ax-selectors.json (RDR-001 §Technical Design L535) so selector
/// drift doesn't require a rebuild.
///
/// `title` exists because Claude.app 1.46388 (rr-ay1) exposes the in-composer
/// Chat/Cowork switch as AXRadioButtons that carry an AXTitle and NO
/// AXDescription — a description-only locator cannot address them.
public struct Selector: Equatable, Codable {
    public let role: String
    public let axDescription: String?
    public let title: String?

    public init(role: String, axDescription: String? = nil, title: String? = nil) {
        self.role = role
        self.axDescription = axDescription
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case axDescription = "description"
        case title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        axDescription = try c.decodeIfPresent(String.self, forKey: .axDescription)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        if axDescription == nil && title == nil {
            throw DriverError.badSelectors("selector for role '\(role)' needs a description or a title")
        }
    }

    /// Pure match predicate against an element's observed attributes. The role
    /// must equal; each text attribute given in the selector must equal the
    /// element's (a nil observed attribute never matches a given one).
    public func matches(role observedRole: String?, description: String?, title observedTitle: String?) -> Bool {
        guard observedRole == role else { return false }
        if let d = axDescription, d != description { return false }
        if let t = title, t != observedTitle { return false }
        return true
    }

    /// Human label for logs / wait timeouts.
    public var label: String {
        var parts: [String] = [role]
        if let d = axDescription { parts.append("desc=\(d)") }
        if let t = title { parts.append("title=\(t)") }
        return parts.joined(separator: ":")
    }
}

/// The locators for one surface (Chat / Code / CoWork): the ordered sequence of
/// elements to press to reach the surface, and the composer text area to set +
/// submit into. `nav` is a sequence because reaching a surface can take more
/// than one press (rr-ay1: Chat = top-left "Chat and Cowork" mode radio, then
/// the composer's "Chat" radio). A legacy single `navButton` key still decodes
/// as a one-element `nav`.
public struct SurfaceSelectors: Equatable, Codable {
    public let nav: [Selector]
    public let composer: Selector

    public init(nav: [Selector], composer: Selector) {
        self.nav = nav
        self.composer = composer
    }

    private enum CodingKeys: String, CodingKey {
        case nav
        case navButton
        case composer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        composer = try c.decode(Selector.self, forKey: .composer)
        if let seq = try c.decodeIfPresent([Selector].self, forKey: .nav) {
            guard !seq.isEmpty else {
                throw DriverError.badSelectors("surface 'nav' must not be empty")
            }
            nav = seq
        } else if let single = try c.decodeIfPresent(Selector.self, forKey: .navButton) {
            nav = [single]
        } else {
            throw DriverError.badSelectors("surface needs 'nav' (sequence) or 'navButton'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nav, forKey: .nav)
        try c.encode(composer, forKey: .composer)
    }
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
        } catch let e as DriverError {
            throw e
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
