// SPDX-License-Identifier: MIT
//
// Unit tests for lib/stage-manager.sh — the pure parse seam of the macOS Stage
// Manager auto-toggle (rr-sm0). macOS Stage Manager (com.apple.WindowManager
// GloballyEnabled) repositions/animates windows on focus changes, which corrupts a
// multi-surface desktop capture (ScreenCaptureKit follows the step-0 window as it
// shrinks). record.sh disables it for the recording and restores it after; this
// tests the decision fn that reads `defaults read … GloballyEnabled` output and
// says whether it is on. spawnSync-sources the lib, the lib/competing-claude.test.mjs
// precedent. The live `defaults`/`killall` wrappers are manual-smoke (consent-sweep
// precedent), not unit-tested here.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, "stage-manager.sh");

// stage_manager_is_enabled_from <output> is a predicate: rc 0 = enabled, 1 = not.
// (Anything other than 0/1 is a contract violation and fails the assertion.)
function enabled(output) {
  const r = spawnSync(
    "bash",
    ["-c", `set -u; source "$1"; stage_manager_is_enabled_from "$2"`, "--", LIB, output],
    { encoding: "utf8" },
  );
  assert.ok(r.status === 0 || r.status === 1, `unexpected rc=${r.status}: ${r.stderr}`);
  return r.status === 0;
}

test('"1" is enabled', () => assert.equal(enabled("1"), true));
test('"0" is NOT enabled', () => assert.equal(enabled("0"), false));
test("empty (key absent / defaults read failed) is NOT enabled", () => assert.equal(enabled(""), false));
test('"garbage" is NOT enabled', () => assert.equal(enabled("garbage"), false));
test('trailing newline is trimmed ("1\\n" -> enabled)', () => assert.equal(enabled("1\n"), true));
test('surrounding whitespace is trimmed (" 1 " -> enabled)', () => assert.equal(enabled(" 1 "), true));
