// SPDX-License-Identifier: MIT
//
// Live AXDriving implementation (RDR-001 §Technical Design L217-242). All AX
// primitives validated in Phase 0 (T2 recording-rig/claude-app-ax-driving-viable
// + -ax-input-submit-mechanism). Runtime behavior is gated by the rr-2pp.3.6
// e2e gate; this file is compile-verified only.

import ApplicationServices
import CoreGraphics
import DesktopDriverCore
import Foundation

final class AXDriver: AXDriving {
    typealias Element = AXUIElement

    private let app: AXUIElement
    private let rigPid: pid_t

    init(rigPid: pid_t) {
        self.rigPid = rigPid
        self.app = AXUIElementCreateApplication(rigPid)
    }

    // INVARIANT 1, re-arm half: flip Chromium's NSAccessibility bridge. The
    // tree only fully materializes (and re-materializes after a re-render) while
    // this is held set — so WaitForStable calls it before every probe.
    func armManualAccessibility() {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    func find(role: String, description: String) -> AXUIElement? {
        search(from: app, role: role, description: description, depth: 0)
    }

    // Bounded DFS for a role + AXDescription match. Depth cap guards against a
    // pathological/cyclic tree (the validated Chat tree is ~265-371 nodes).
    private func search(from element: AXUIElement, role: String, description: String, depth: Int) -> AXUIElement? {
        if depth > 80 { return nil }
        if stringAttr(element, kAXRoleAttribute) == role,
           stringAttr(element, kAXDescriptionAttribute) == description {
            return element
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = search(from: child, role: role, description: description, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func stringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    @discardableResult
    func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    // AXValue-set the composer (element-scoped — safe). Focus first so the
    // framework treats it as the active field. Note: this alone does NOT submit
    // (the Send button never enables); the process-targeted Return does.
    @discardableResult
    func setValue(_ element: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success
    }

    func windowSize() -> Size? {
        guard let window = mainWindow() else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else { return nil }
        return Size(width: Double(size.width), height: Double(size.height))
    }

    @discardableResult
    func setWindowSize(_ size: Size) -> Bool {
        guard let window = mainWindow() else { return false }
        var cg = CGSize(width: size.width, height: size.height)
        guard let axValue = AXValueCreate(.cgSize, &cg) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue) == .success
    }

    private func mainWindow() -> AXUIElement? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &ref) == .success,
           let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement], let first = windows.first {
            return first
        }
        return nil
    }

    // INVARIANT 2: submit ONLY via a process-targeted Return — postToPid(rigPid).
    // A global CGEvent.post(tap:) leaks to the system-frontmost app (it leaked a
    // prompt into the operator terminal during Phase 0). There is deliberately
    // no global-post path in this type.
    func postReturnKeyToRig() {
        let source = CGEventSource(stateID: .privateState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        keyDown?.postToPid(rigPid)
        keyUp?.postToPid(rigPid)
    }
}
