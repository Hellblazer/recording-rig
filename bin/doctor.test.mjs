// SPDX-License-Identifier: MIT
//
// Integration tests for the doctor soft-miss warning (RDR-001 Phase 3 Step 2,
// rr-2pp.4.2). Runs bin/doctor.sh with RIG_QUALITY_LOG pointed at a fixture and
// asserts ONLY the soft-miss line's presence/absence — never doctor's exit code
// (other prereq checks vary by environment, so the exit code is not asserted).

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir, platform } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DOCTOR = join(HERE, "doctor.sh");

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
