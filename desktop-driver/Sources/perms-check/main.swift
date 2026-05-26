// SPDX-License-Identifier: MIT
//
// perms-check — report this process's Accessibility + Screen-Recording TCC
// grants as a single line of JSON (RDR-001 Phase 5 Step 1, rr-2pp.6.1.1 /
// rr-nke). Consumed by `doctor` (lib/desktop-doctor.sh) so the desktop-mode
// preflight can WARN when the controlling process is missing a permission the
// live driver needs, and point the operator at the exact System Settings pane.
//
// Output (stdout, exactly one line, then exit 0):
//
//     {"accessibility":true,"screenRecording":false}
//
//   accessibility    — AXIsProcessTrusted(): may this process drive the AX
//                       tree (AXManualAccessibility arm + value-set + AXPress)?
//   screenRecording  — CGPreflightScreenCaptureAccess(): may this process
//                       capture the screen (ScreenCaptureKit)? Preflight only:
//                       it never prompts and never mutates TCC state.
//
// WHY NSApplication(.accessory): CGPreflightScreenCaptureAccess is a
// CoreGraphics call and aborts with CGS_REQUIRE_INIT if the window-server
// connection was never initialized. bin/desktop-driver hits the same wall and
// fixes it the same way — bootstrap NSApplication as .accessory (no Dock icon,
// no focus steal) BEFORE the first CG call. AXIsProcessTrusted needs no such
// bootstrap, so it is read first and the policy is set only for the CG read.
//
// TCC-ATTRIBUTES-TO-PARENT CAVEAT: a CLI helper does not own an independent TCC
// identity — grants attach to the *responsible* process (the terminal app, or
// whatever launched the doctor run). perms-check therefore reports the grants
// of ITS OWN process, which doctor uses as a PROXY for the environment
// bin/desktop-driver will run in (same shell, same responsible parent). If
// doctor is invoked from a context whose Accessibility/Screen-Recording grant
// differs from the eventual record.sh context, the proxy can disagree with
// reality — hence doctor treats this as a WARN, never a hard gate.

import AppKit
import ApplicationServices
import Foundation

// Accessibility first: AXIsProcessTrusted needs no window-server connection,
// and reading it before the .accessory bootstrap keeps the two reads
// independent (a CGS failure can never mask the AX result).
let accessibility = AXIsProcessTrusted()

// INVARIANT (mirrors bin/desktop-driver): init NSApplication as .accessory
// BEFORE any CoreGraphics call, else CGPreflightScreenCaptureAccess aborts with
// CGS_REQUIRE_INIT. .accessory keeps this helper out of the Dock and prevents
// it from stealing focus from the live Claude-Rig window.
NSApplication.shared.setActivationPolicy(.accessory)

let screenRecording = CGPreflightScreenCaptureAccess()

// Single compact line so callers can `jq` it without buffering. Booleans are
// emitted as bare JSON literals (not "true"/"false" strings) so the shape check
// `.accessibility | type == "boolean"` holds.
print("{\"accessibility\":\(accessibility),\"screenRecording\":\(screenRecording)}")
