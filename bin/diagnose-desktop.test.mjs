// SPDX-License-Identifier: MIT
//
// Tests for bin/diagnose-desktop.sh — the desktop forensic report (RDR-001
// Phase 3 Step 3, rr-2pp.4.3). Read-only forensics over a session's artifacts:
// (a) checkpoint coverage, (b) soft-miss trend, (c) capture coverage, (d)
// bridge-log liveness. Explicitly NO HAR/Playwright-trace forensics.
//
// The helper reads session artifacts from ${RIG_TMP:-/tmp}, the quality log from
// ${RIG_QUALITY_LOG}, and the bridge log from ${RIG_CLAUDE_LOGS_DIR}; tests pin
// all three at temp dirs so nothing touches the real /tmp or ~/Library.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DIAG = join(HERE, "diagnose-desktop.sh");

// One transcript NDJSON line in the bridge's field order.
function tline(tool, args, result) {
  return JSON.stringify({ ts: "2026-05-25T12:00:00.000Z", tool, args, result, session: "sess1" });
}

// A fully-populated session fixture. Returns the env + dir handles. `opts`:
//   checkpoints  : spec.desktop.checkpoints[] (default one required "compiled")
//   transcript   : array of NDJSON lines (default: checkpoint + genuine turn_end)
//   quality      : array of quality.jsonl lines (default: empty)
//   bridgeLog    : string contents for the bridge log (default: omitted -> no log)
//   writeSpec    : whether to write the spec file (default true)
function fixture(opts = {}) {
  const tmpRoot = mkdtempSync(join(tmpdir(), "rig-diag-tmp-"));
  const logsDir = mkdtempSync(join(tmpdir(), "rig-diag-logs-"));
  const qDir = mkdtempSync(join(tmpdir(), "rig-diag-q-"));
  const session = "sess1";

  const checkpoints = opts.checkpoints ?? [{ name: "compiled", required: true }];
  if (opts.writeSpec ?? true) {
    writeFileSync(
      join(tmpRoot, "spec.json"),
      JSON.stringify({ backend: "desktop", desktop: { surface: "chat", checkpoints } }),
    );
  }
  const transcript = opts.transcript ?? [
    tline("rig_checkpoint", { name: "compiled" }, { ok: true }),
    tline("rig_turn_end", {}, { ok: true }),
  ];
  if (transcript.length) {
    writeFileSync(join(tmpRoot, `${session}.bridge-transcript.jsonl`), transcript.join("\n") + "\n");
  }
  const quality = opts.quality ?? [];
  const qlog = join(qDir, "quality.jsonl");
  if (quality.length) writeFileSync(qlog, quality.join("\n") + "\n");

  if (opts.bridgeLog !== undefined) {
    writeFileSync(join(logsDir, "mcp-server-Recording Rig Bridge.log"), opts.bridgeLog);
  }

  return {
    session,
    spec: join(tmpRoot, "spec.json"),
    env: { RIG_TMP: tmpRoot, RIG_CLAUDE_LOGS_DIR: logsDir, RIG_QUALITY_LOG: qlog },
  };
}

function run({ session, spec, env }, passSpec = true) {
  const args = passSpec && spec ? [session, spec] : [session];
  const r = spawnSync("bash", [DIAG, ...args], { encoding: "utf8", env: { ...process.env, ...env } });
  return r;
}

function qrow(soft_miss, session = "sess1") {
  return JSON.stringify({
    ts: "2026-05-25T12:00:00.000Z", session, spec: "x.json", backend: "desktop",
    surface: "chat", soft_miss, validate_pass: true, idle_rc: soft_miss ? 2 : 0,
  });
}

test("usage error when no session argument", () => {
  const r = spawnSync("bash", [DIAG], { encoding: "utf8" });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /usage/i);
});

test("reports complete checkpoint coverage and a genuine turn_end", () => {
  const r = run(fixture());
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /checkpoint coverage/);
  assert.match(r.stdout, /complete: all required checkpoints called/);
  assert.match(r.stdout, /turn_end: present \(genuine\)/);
});

test("flags a missing required checkpoint", () => {
  const r = run(fixture({
    transcript: [tline("rig_turn_end", {}, { ok: true })], // no checkpoint called
  }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /MISSING REQUIRED: compiled/);
});

test("detects a synthesized (fallback) turn_end", () => {
  const r = run(fixture({
    transcript: [
      tline("rig_checkpoint", { name: "compiled" }, { ok: true }),
      tline("rig_turn_end", {}, { ok: true, synthesized: true }),
    ],
  }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /turn_end: present \(synthesized\)/);
});

test("flags an absent turn_end", () => {
  const r = run(fixture({
    transcript: [tline("rig_checkpoint", { name: "compiled" }, { ok: true })],
  }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /turn_end: ABSENT/);
});

test("skips checkpoint coverage gracefully when no spec is provided", () => {
  const r = run(fixture(), false); // do not pass spec
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /checkpoint coverage skipped \(no spec provided\)/);
});

test("section (a) stays correct when the transcript has a malformed line", () => {
  // A truncated/partial line (process kill, rotation) must not abort the slurp
  // into a FALSE "all required checkpoints called" / "turn_end ABSENT".
  const r = run(fixture({
    transcript: [
      tline("rig_checkpoint", { name: "compiled" }, { ok: true }),
      "NOT VALID JSON {{{",
      tline("rig_turn_end", {}, { ok: true }),
    ],
  }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /complete: all required checkpoints called/);
  assert.match(r.stdout, /turn_end: present \(genuine\)/);
});

test("rejects a SESSION with path-traversal characters", () => {
  const r = spawnSync("bash", [DIAG, "../evil"], { encoding: "utf8" });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /SESSION must match/);
});

test("surfaces the soft-miss trend and this-session entry", () => {
  const r = run(fixture({
    quality: [qrow(false), qrow(false), qrow(true), qrow(true, "sess1")],
  }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /soft-miss trend/);
  assert.match(r.stdout, /rate: \d+% over last \d+ desktop runs/);
  assert.match(r.stdout, /this-session:.*soft_miss=true/);
});

test("notes when this session has no quality.jsonl entry", () => {
  const r = run(fixture({ quality: [qrow(false, "other")] }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /no quality\.jsonl entry for this session/);
});

test("capture coverage reports mov missing and a transcript span", () => {
  const r = run(fixture()); // default fixture has no .mov
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /capture coverage/);
  assert.match(r.stdout, /mov.*(MISSING|not found)/i);
  assert.match(r.stdout, /transcript_span_s:/);
});

test("bridge-log liveness: NOT FOUND when the log is absent", () => {
  const r = run(fixture()); // no bridgeLog written
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /bridge-log liveness/);
  assert.match(r.stdout, /NOT FOUND/);
});

test("bridge-log liveness: present, with tail lines", () => {
  const r = run(fixture({
    bridgeLog: "2026-05-25T12:00:00Z [Recording Rig Bridge] [info] running on stdio\n" +
               "2026-05-25T12:01:00Z [Recording Rig Bridge] [info] Server transport closed\n",
  }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /status: present/);
  assert.match(r.stdout, /running on stdio|transport closed/);
});

test("explicitly states HAR/trace forensics are excluded", () => {
  const r = run(fixture());
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /HAR.*Playwright-trace.*N\/A/);
});

test("reports a missing transcript (bridge never reached)", () => {
  const r = run(fixture({ transcript: [] }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /transcript:.*(MISSING|not found)/i);
});
