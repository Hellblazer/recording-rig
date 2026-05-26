// SPDX-License-Identifier: MIT
//
// Integration tests for the doctor soft-miss warning (RDR-001 Phase 3 Step 2,
// rr-2pp.4.2). Runs bin/doctor.sh with RIG_QUALITY_LOG pointed at a fixture and
// asserts ONLY the soft-miss line's presence/absence — never doctor's exit code
// (other prereq checks vary by environment, so the exit code is not asserted).
//
// Also: the desktop-doctor seam regression (RDR-001 Phase 5 Step 1, rr-njj) —
// proving the section-7 relocation into lib/desktop-doctor.sh preserved every
// Desktop WARN check, the subcommand dispatch is wired, and the no-arg CLI flow
// is unchanged for CLI-backend users.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir, platform } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DOCTOR = join(HERE, "doctor.sh");
const REPO_BRIDGE_DIR = join(HERE, "..", "bridge");

function row(soft_miss) {
  return JSON.stringify({
    ts: "2026-05-25T00:00:00.000Z",
    session: "s",
    spec: "x.json",
    backend: "desktop",
    surface: "chat",
    soft_miss,
    validate_pass: true,
    idle_rc: soft_miss ? 2 : 0,
  });
}

function runDoctor(logPath) {
  const r = spawnSync("bash", [DOCTOR], {
    encoding: "utf8",
    env: { ...process.env, RIG_QUALITY_LOG: logPath },
  });
  return (r.stdout || "") + (r.stderr || ""); // warn() goes to stderr, ok() to stdout
}

function fixture(rows) {
  const dir = mkdtempSync(join(tmpdir(), "rig-doctor-"));
  const log = join(dir, "quality.jsonl");
  writeFileSync(log, rows.join("\n") + "\n");
  return log;
}

// Args-aware runner returning both combined output and exit status.
function runDoctorArgs(args = [], env = {}) {
  const r = spawnSync("bash", [DOCTOR, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
  return { out: (r.stdout || "") + (r.stderr || ""), status: r.status };
}

// The soft-miss check is gated behind the Darwin block; skip elsewhere.
const darwin = platform() === "darwin";

test("doctor warns when soft-miss rate exceeds 20%", { skip: !darwin }, () => {
  const log = fixture([...Array(6).fill(row(false)), ...Array(4).fill(row(true))]); // 40%
  const out = runDoctor(log);
  assert.match(out, /soft-miss rate 40% over last 10 runs \(>20%\)/);
  assert.match(out, /skipping rig\.turn_end/);
});

test("doctor reports a clean soft-miss rate without warning", { skip: !darwin }, () => {
  const log = fixture(Array(10).fill(row(false))); // 0%
  const out = runDoctor(log);
  assert.match(out, /soft-miss rate 0% over last 10 runs/);
  assert.doesNotMatch(out, />20%/);
});

test("doctor is silent on the soft-miss trend below the 3-run sample floor", { skip: !darwin }, () => {
  const log = fixture([row(true)]); // 100% but only 1 sample
  const out = runDoctor(log);
  assert.doesNotMatch(out, /soft-miss rate/);
});

// --- rr-njj: section-7 relocation + dispatch regression ---

test("doctor no-arg: every relocated Desktop WARN check still appears", { skip: !darwin }, () => {
  const dir = mkdtempSync(join(tmpdir(), "rig-doctor-reloc-"));
  // Stub perms-check -> both denied, so the Accessibility / Screen-Recording
  // WARNs and their exact pane hints fire deterministically.
  const perms = join(dir, "perms-check");
  writeFileSync(perms, `#!/usr/bin/env bash\necho '{"accessibility":false,"screenRecording":false}'\n`);
  chmodSync(perms, 0o755);
  const { out, status } = runDoctorArgs([], {
    RIG_QUALITY_LOG: "/dev/null",
    RIG_PERMS_CHECK: perms,
    CLAUDE_RIG_DIR: join(dir, "Claude-Rig"), // absent profile -> warn
    RIG_BRIDGE_SETTINGS: join(dir, "bridge.json"), // absent bridge -> warn
    RIG_SELECTOR_CACHE: join(dir, "sel.json"), // absent -> warn
    RIG_PROBE_CACHE: join(dir, "probe.json"), // absent -> warn
  });
  // Original CLI checks still ran (sections 1-2, untouched by the relocation).
  assert.match(out, /checking prereqs/);
  assert.match(out, /node on PATH/);
  assert.match(out, /bash version/);
  // Relocated + new Desktop checks all present (proves nothing was dropped).
  for (const s of [
    "ffmpeg",
    "swiftc",
    "Claude.app",
    "Accessibility permission",
    "Screen Recording permission",
    "Claude-Rig profile",
    "recording-rig-bridge",
    "AX-selector probe cache",
    "surface MCP-probe cache",
  ]) {
    assert.ok(out.includes(s), `relocated desktop check missing: ${s}`);
  }
  // Exact System Settings pane hints preserved.
  assert.match(out, /System Settings > Privacy & Security > Accessibility/);
  assert.match(out, /System Settings > Privacy & Security > Screen Recording/);
  // Desktop checks are advisory — none emit a hard-fail ✗ marker.
  assert.doesNotMatch(out, /✗ +(ffmpeg|swiftc|Claude\.app|Accessibility|Screen Recording|Claude-Rig|recording-rig-bridge|AX-selector|surface MCP)/);
  // CLI hard checks pass on this machine -> exit 0 despite the desktop WARNs
  // (the advisory checks never change the exit code).
  assert.equal(status, 0, out);
});

test("doctor --verify-bridge dispatches and skips the standard checks", { skip: !darwin }, () => {
  const { out, status } = runDoctorArgs(["--verify-bridge"], { RIG_BRIDGE_EXT_DIR: REPO_BRIDGE_DIR });
  assert.equal(status, 0, out);
  assert.match(out, /well-formed/);
  assert.doesNotMatch(out, /checking prereqs/, "subcommand mode must not run the prereq checks");
});

test("doctor unknown subcommand exits 2 with usage", { skip: !darwin }, () => {
  const { out, status } = runDoctorArgs(["--bogus"]);
  assert.equal(status, 2);
  assert.match(out, /unknown subcommand/);
  assert.match(out, /--install-bridge/);
});

test("doctor no-arg does not dispatch any subcommand", () => {
  const { out } = runDoctorArgs([], { RIG_QUALITY_LOG: "/dev/null" });
  assert.match(out, /checking prereqs/);
  assert.doesNotMatch(out, /unknown subcommand/);
  assert.doesNotMatch(out, /not yet implemented/);
});
