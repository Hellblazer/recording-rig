// SPDX-License-Identifier: MIT
//
// Unit tests for lib/quality.sh — the soft-miss aggregation layer (RDR-001
// Phase 3 Step 2, rr-2pp.4.2). Shell functions are exercised by sourcing
// quality.sh in a bash subprocess and calling the function under test, the
// same spawnSync pattern bin/validate.test.mjs uses for node.
//
// Covered:
//   quality_log_path            — env override + default location
//   quality_log_append          — creates parent dirs, appends NDJSON
//   quality_synthesize_turn_end — appends a fallback rig_turn_end the validator
//                                 accepts (last call == rig_turn_end), marked
//                                 result.synthesized so diagnose can tell it
//                                 from a genuine model call
//   quality_soft_miss_rate      — "<pct> <count>" over the last N desktop runs

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const QUALITY = join(HERE, "quality.sh");
const VALIDATE = join(HERE, "..", "bin", "validate.mjs");

// Run one quality.sh function. `body` is bash run after `source quality.sh`.
function sh(body, env = {}) {
  const r = spawnSync("bash", ["-c", `set -eu; source "${QUALITY}"; ${body}`], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
  return r;
}

function tmp() {
  return mkdtempSync(join(tmpdir(), "rig-quality-"));
}

// A quality.jsonl line for a desktop run.
function row({ soft_miss = false, backend = "desktop", validate_pass = true } = {}) {
  return JSON.stringify({
    ts: "2026-05-25T00:00:00.000Z",
    session: "s",
    spec: "x.json",
    backend,
    surface: "chat",
    soft_miss,
    validate_pass,
    idle_rc: soft_miss ? 2 : 0,
  });
}

test("quality_log_path honours RIG_QUALITY_LOG override", () => {
  const r = sh('quality_log_path', { RIG_QUALITY_LOG: "/tmp/custom/quality.jsonl" });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "/tmp/custom/quality.jsonl");
});

test("quality_log_path defaults under Application Support when unset", () => {
  // Unset the override; pin HOME so the default is deterministic.
  const r = spawnSync("bash", ["-c", `set -eu; unset RIG_QUALITY_LOG; source "${QUALITY}"; quality_log_path`], {
    encoding: "utf8",
    env: { ...process.env, HOME: "/Users/test", RIG_QUALITY_LOG: "" },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "/Users/test/Library/Application Support/recording-rig/quality.jsonl");
});

test("quality_log_append creates parent dirs and appends NDJSON lines", () => {
  const dir = tmp();
  const log = join(dir, "nested", "quality.jsonl"); // nested dir does not exist yet
  const env = { RIG_QUALITY_LOG: log };
  let r = sh(`quality_log_append '${row({ soft_miss: false })}'`, env);
  assert.equal(r.status, 0, r.stderr);
  r = sh(`quality_log_append '${row({ soft_miss: true })}'`, env);
  assert.equal(r.status, 0, r.stderr);

  assert.ok(existsSync(log));
  const lines = readFileSync(log, "utf8").split("\n").filter((l) => l.trim());
  assert.equal(lines.length, 2);
  assert.equal(JSON.parse(lines[0]).soft_miss, false);
  assert.equal(JSON.parse(lines[1]).soft_miss, true);
  // Each line is valid standalone JSON (NDJSON, trailing newline).
  assert.ok(readFileSync(log, "utf8").endsWith("\n"));
});

test("quality_synthesize_turn_end appends a validator-acceptable fallback turn_end", () => {
  const dir = tmp();
  const transcript = join(dir, "s.bridge-transcript.jsonl");
  // A transcript where the model called a checkpoint but skipped turn_end.
  const t = (tool, args, result) =>
    JSON.stringify({ ts: "2026-05-25T00:00:00.000Z", tool, args, result, session: "s" }) + "\n";
  writeFileSync(transcript, t("rig_checkpoint", { name: "compiled" }, { ok: true }));

  const r = sh(`quality_synthesize_turn_end "${transcript}" "s"`, {});
  assert.equal(r.status, 0, r.stderr);

  const lines = readFileSync(transcript, "utf8").split("\n").filter((l) => l.trim());
  assert.equal(lines.length, 2);
  const last = JSON.parse(lines[1]);
  assert.equal(last.tool, "rig_turn_end");
  assert.equal(last.session, "s");
  assert.equal(last.result.synthesized, true, "synthesized marker for diagnose forensics");
  assert.equal(last.result.ok, true);
});

test("synthesized turn_end makes a soft-miss transcript PASS validation", () => {
  const dir = tmp();
  const transcript = join(dir, "s.bridge-transcript.jsonl");
  const spec = join(dir, "spec.json");
  writeFileSync(spec, JSON.stringify({
    backend: "desktop",
    desktop: { surface: "chat", checkpoints: [{ name: "compiled", required: true }] },
  }));
  const t = (tool, args, result) =>
    JSON.stringify({ ts: "2026-05-25T00:00:00.000Z", tool, args, result, session: "s" }) + "\n";
  // Model hit the required checkpoint but skipped turn_end.
  writeFileSync(transcript, t("rig_checkpoint", { name: "compiled" }, { ok: true }));

  // Before synthesis: validator FAILS (last call is not rig_turn_end).
  let v = spawnSync("node", [VALIDATE, spec, transcript], { encoding: "utf8" });
  assert.equal(v.status, 1, "expected FAIL before synthesis");
  assert.match(v.stderr, /rig_turn_end/);

  // Synthesize the fallback, then the same validator PASSES.
  const s = sh(`quality_synthesize_turn_end "${transcript}" "s"`, {});
  assert.equal(s.status, 0, s.stderr);
  v = spawnSync("node", [VALIDATE, spec, transcript], { encoding: "utf8" });
  assert.equal(v.status, 0, `expected PASS after synthesis: ${v.stderr}`);
});

test("synthesized turn_end does NOT rescue a missing required checkpoint", () => {
  // Gate invariant: required-checkpoint failure still produces no GIF; only the
  // turn_end-skip (soft miss) is rescued.
  const dir = tmp();
  const transcript = join(dir, "s.bridge-transcript.jsonl");
  const spec = join(dir, "spec.json");
  writeFileSync(spec, JSON.stringify({
    backend: "desktop",
    desktop: { surface: "chat", checkpoints: [{ name: "compiled", required: true }] },
  }));
  const t = (tool, args, result) =>
    JSON.stringify({ ts: "2026-05-25T00:00:00.000Z", tool, args, result, session: "s" }) + "\n";
  // Model produced output but missed the required checkpoint AND turn_end.
  writeFileSync(transcript, t("rig_emit", { name: "note" }, { ok: true }));

  sh(`quality_synthesize_turn_end "${transcript}" "s"`, {});
  const v = spawnSync("node", [VALIDATE, spec, transcript], { encoding: "utf8" });
  assert.equal(v.status, 1, "missing checkpoint must still FAIL even with synthesized turn_end");
  assert.match(v.stderr, /checkpoint 'compiled' missing/);
});

test("quality_soft_miss_rate returns '0 0' for a missing or empty log", () => {
  const dir = tmp();
  let r = sh(`quality_soft_miss_rate "${join(dir, "absent.jsonl")}" 20`, {});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0 0");

  const empty = join(dir, "empty.jsonl");
  writeFileSync(empty, "");
  r = sh(`quality_soft_miss_rate "${empty}" 20`, {});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0 0");
});

test("quality_soft_miss_rate computes integer percent over last N desktop runs", () => {
  const dir = tmp();
  const log = join(dir, "quality.jsonl");
  // 7 clean + 3 soft = 30% over 10.
  const rows = [
    ...Array(7).fill(row({ soft_miss: false })),
    ...Array(3).fill(row({ soft_miss: true })),
  ];
  writeFileSync(log, rows.join("\n") + "\n");
  const r = sh(`quality_soft_miss_rate "${log}" 20`, {});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "30 10");
});

test("quality_soft_miss_rate windows to the last N runs", () => {
  const dir = tmp();
  const log = join(dir, "quality.jsonl");
  // 10 old soft-misses, then 5 clean. Window N=5 -> 0% over 5.
  const rows = [
    ...Array(10).fill(row({ soft_miss: true })),
    ...Array(5).fill(row({ soft_miss: false })),
  ];
  writeFileSync(log, rows.join("\n") + "\n");
  const r = sh(`quality_soft_miss_rate "${log}" 5`, {});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0 5");
});

test("quality_soft_miss_rate tolerates malformed lines (per-line, not whole-file abort)", () => {
  // The RDR tells operators to truncate/rotate this log manually, so a partial
  // or garbage line must not silence the advisory. Garbage + a non-object JSON
  // value are both skipped; the rate is computed over the valid desktop rows.
  const dir = tmp();
  const log = join(dir, "quality.jsonl");
  const lines = [
    row({ soft_miss: false }),
    "this is not json {{{",
    row({ soft_miss: true }),
    "42", // valid JSON, but not an object
    row({ soft_miss: false }),
    "", // blank line
  ];
  writeFileSync(log, lines.join("\n") + "\n");
  const r = sh(`quality_soft_miss_rate "${log}" 20`, {});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "33 3"); // 1 soft of 3 valid desktop rows -> floor(33.3)
});

test("quality_soft_miss_rate excludes non-desktop rows from the denominator", () => {
  const dir = tmp();
  const log = join(dir, "quality.jsonl");
  // 2 desktop soft + 8 cli clean. Desktop-only denominator -> 100% over 2.
  const rows = [
    ...Array(2).fill(row({ soft_miss: true, backend: "desktop" })),
    ...Array(8).fill(row({ soft_miss: false, backend: "cli" })),
  ];
  writeFileSync(log, rows.join("\n") + "\n");
  const r = sh(`quality_soft_miss_rate "${log}" 20`, {});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "100 2");
});
