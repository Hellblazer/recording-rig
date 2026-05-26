// SPDX-License-Identifier: MIT
//
// ax-dump — a read-only AX-tree dumper for discovering surface selectors
// (RDR-001 Phase 4 Step 1, rr-2pp.5.1; seeds the Phase 5 `doctor
// --probe-surfaces` discovery, rr-2pp.6.1).
//
// Why this exists: the Code / CoWork composer selectors are not knowable
// without reading the live Claude-Rig AX tree, and Chromium's a11y bridge
// COLLAPSES after a navigation re-render (T2 claude-app-ax-driving-viable:
// short-lived arm→exit processes make the tree flap). So this dumper holds
// the connection open and RE-ARMS `AXManualAccessibility` on every snapshot
// (INVARIANT 1), printing a fresh snapshot every `interval` seconds. The
// operator navigates the live app between snapshots; a high node count means
// the tree materialized, a low count means it collapsed (re-arm again).
//
// STRICTLY read-only: it sets AXManualAccessibility (the same arm the driver
// uses) and reads attributes. It performs NO AXPress, sets NO value, posts NO
// CGEvent, and never touches window geometry or capture. Safe to run against
// a live session you care about.
//
// Usage:  ax-dump <pid> [interval-seconds]
//         ax-dump $(pgrep -x Claude-Rig)

import ApplicationServices
import Foundation

// Roles worth surfacing for selector authoring. The composer is an AXTextArea
// on Chat; AXTextField is included in case a surface differs. AXButton covers
// nav tabs and Send. Override with RIG_AXDUMP_ROLES (comma-separated) to widen
// the net for non-button UI like the Code folder picker (menu items / cells).
let interestingRoles: Set<String> = {
  if let env = ProcessInfo.processInfo.environment["RIG_AXDUMP_ROLES"], !env.isEmpty {
    return Set(env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
  }
  return ["AXTextArea", "AXTextField", "AXButton"]
}()

func stringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
    return ref as? String
}

func actions(_ element: AXUIElement) -> [String] {
    var ref: CFArray?
    guard AXUIElementCopyActionNames(element, &ref) == .success,
          let names = ref as? [String] else { return [] }
    return names
}

func valueSettable(_ element: AXUIElement) -> Bool {
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else {
        return false
    }
    return settable.boolValue
}

struct Node {
    let role: String
    let description: String
    let title: String
    let acts: [String]
    let settable: Bool
}

// Bounded DFS mirroring AXDriver.search's depth cap. Returns total nodes
// visited plus the interesting matches, so the caller can report tree size
// (the materialized-vs-collapsed signal).
func walk(_ element: AXUIElement, depth: Int, total: inout Int, hits: inout [Node]) {
    if depth > 80 { return }
    total += 1
    let role = stringAttr(element, kAXRoleAttribute) ?? ""
    if interestingRoles.contains(role) {
        hits.append(Node(
            role: role,
            description: stringAttr(element, kAXDescriptionAttribute) ?? "",
            title: stringAttr(element, kAXTitleAttribute) ?? "",
            acts: actions(element),
            settable: role == "AXTextArea" || role == "AXTextField" ? valueSettable(element) : false
        ))
    }
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else { return }
    for child in children { walk(child, depth: depth + 1, total: &total, hits: &hits) }
}

// --- entry point ---

let args = CommandLine.arguments
guard args.count >= 2, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: ax-dump <pid> [interval-seconds]\n".utf8))
    exit(2)
}
// A non-positive interval would print a confusing "interval=-1.0s" and (via the
// max(0,...) floor below) silently behave like 0; reject it loudly instead.
let rawInterval = args.count >= 3 ? (Double(args[2]) ?? 2.0) : 2.0
let interval = rawInterval > 0 ? rawInterval : 2.0
if rawInterval <= 0 {
    FileHandle.standardError.write(Data(
        "ax-dump: non-positive interval '\(args[2])' ignored; using \(interval)s\n".utf8))
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data(
        "ax-dump: this process lacks Accessibility permission. Grant it to the terminal/app running ax-dump in System Settings > Privacy & Security > Accessibility, then retry.\n".utf8))
    exit(3)
}

let app = AXUIElementCreateApplication(pid)

// Fail fast on a wrong/stale pid. AXUIElementCreateApplication never fails (it
// returns an opaque handle even for a dead pid); the error only surfaces on the
// first attribute read. Probe the app-level AXRole now — it is readable without
// arming on a live GUI app — so a bad pid produces a clear message instead of a
// silent "nodes=0" first snapshot.
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
var probeRef: CFTypeRef?
if AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &probeRef) != .success {
    FileHandle.standardError.write(Data(
        "ax-dump: pid \(pid) is not an attachable GUI application (wrong or stale pid?). Re-resolve it with pgrep and retry.\n".utf8))
    exit(4)
}

let fmt = DateFormatter()
fmt.dateFormat = "HH:mm:ss"

print("ax-dump: pid=\(pid) interval=\(interval)s — navigate Claude-Rig between snapshots; Ctrl-C to stop.")
print("read-only: arms AXManualAccessibility + reads attributes; no press/set/post.\n")

while true {
    // INVARIANT 1: re-arm before every probe — the bridge drops on re-render.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    // Brief settle so a just-armed tree has materialized before the walk.
    Thread.sleep(forTimeInterval: 0.4)

    var total = 0
    var hits: [Node] = []
    walk(app, depth: 0, total: &total, hits: &hits)

    print("[\(fmt.string(from: Date()))] nodes=\(total)  (low count => a11y collapsed; navigate/wait and it re-arms)")
    if hits.isEmpty {
        print("  (no AXTextArea/AXTextField/AXButton found — tree likely collapsed)")
    }
    for n in hits {
        let bits = [
            n.role.padding(toLength: 12, withPad: " ", startingAt: 0),
            "desc=\(n.description.isEmpty ? "-" : "'\(n.description)'")",
            "title=\(n.title.isEmpty ? "-" : "'\(n.title)'")",
            n.settable ? "[value-settable]" : "",
            n.acts.isEmpty ? "" : "actions=\(n.acts.joined(separator: ","))",
        ].filter { !$0.isEmpty }
        print("  " + bits.joined(separator: "  "))
    }
    print("")
    Thread.sleep(forTimeInterval: max(0, interval - 0.4))
}
