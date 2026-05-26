// SPDX-License-Identifier: MIT
//
// rr-2pp.4.1 — validator backend-awareness tests. Spawns bin/validate.mjs as a
// child (black-box, like the bridge tests) and asserts the exit code + output.
// The exit code is the GIF gate: 0 => render, non-zero => refuse.
//
//   CLI path:     validate.mjs <spec> <cast>                 (backend absent/"cli")
//   desktop path: validate.mjs <spec> <transcript> [<mov>]   (backend "desktop")

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const VALIDATE = join(here, "validate.mjs");

function sandbox() {
  return mkdtempSync(join(tmpdir(), "rigval-"));
}

// Run validate.mjs against a spec + data file (cast or transcript). Returns the
// exit code + captured streams.
function run(dir, spec, { dataName, dataContent, movPath, env } = {}) {
  const specPath = join(dir, "spec.json");
  writeFileSync(specPath, JSON.stringify(spec));
  const dataPath = join(dir, dataName);
  writeFileSync(dataPath, dataContent);
  const args = [VALIDATE, specPath, dataPath];
  if (movPath) args.push(movPath);
  const r = spawnSync("node", args, { encoding: "utf8", env: { ...process.env, ...env } });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

// Build an NDJSON transcript from [{tool, args}] (one bridge call per line).
function transcript(calls) {
  return calls
    .map((c) => JSON.stringify({
      ts: "2026-05-25T00:00:00.000Z",
      tool: c.tool,
      args: c.args ?? {},
      result: c.result ?? { ok: true },
      session: "sess",
    }))
    .join("\n") + "\n";
}

const CAST_HEADER = JSON.stringify({ version: 2, width: 80, height: 24 });
function cast(text) {
  return CAST_HEADER + "\n" + JSON.stringify([0.1, "o", text]) + "\n";
}

// Build an Agent-SDK audit.jsonl (CoWork / agent-transcript-tail) from event objects.
function audit(events) {
  return events.map((e) => JSON.stringify(e)).join("\n") + "\n";
}
// A clean CoWork turn: init, a tool call, then a successful result.
const AUDIT_OK = [
  { type: "system", subtype: "init" },
  { type: "assistant", message: { content: [{ type: "tool_use", name: "Write" }] } },
  { type: "result", subtype: "success", is_error: false, num_turns: 2, result: "created notes.txt" },
];

// ── CLI path must stay byte-identical in behavior ───────────────────────────

test("CLI cast: must_contain present => PASS (exit 0)", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { validate: { must_contain: ["ANSWER=42"] } },
      { dataName: "out.cast", dataContent: cast("hello ANSWER=42 world") });
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /PASSED/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("CLI cast: forbidden marker => FAIL (exit 1)", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { validate: { must_not_contain: ["step_aborted"] } },
      { dataName: "out.cast", dataContent: cast("... step_aborted ...") });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /FAILED/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ── desktop path: transcript is primary input ───────────────────────────────

test("desktop: required checkpoint in order + last call rig_turn_end => PASS", () => {
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", desktop: { checkpoints: [{ name: "built", required: true }] },
        validate: { must_contain: ["built"] } },
      { dataName: "t.jsonl", dataContent: transcript([
        { tool: "rig_checkpoint", args: { name: "built" } },
        { tool: "rig_turn_end" },
      ]) });
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /PASSED/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: missing required checkpoint => FAIL and names it", () => {
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", desktop: { checkpoints: [{ name: "tests_passed", required: true }] } },
      { dataName: "t.jsonl", dataContent: transcript([
        { tool: "rig_checkpoint", args: { name: "built" } },
        { tool: "rig_turn_end" },
      ]) });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /tests_passed/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: required checkpoints out of order => FAIL", () => {
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", desktop: { checkpoints: [
        { name: "a", required: true }, { name: "b", required: true }] } },
      { dataName: "t.jsonl", dataContent: transcript([
        { tool: "rig_checkpoint", args: { name: "b" } },
        { tool: "rig_checkpoint", args: { name: "a" } },
        { tool: "rig_turn_end" },
      ]) });
    assert.equal(r.code, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: ALL missing required checkpoints are reported (not just the first)", () => {
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", desktop: { checkpoints: [
        { name: "a", required: true }, { name: "b", required: true }, { name: "c", required: true }] } },
      { dataName: "t.jsonl", dataContent: transcript([
        { tool: "rig_checkpoint", args: { name: "b" } },
        { tool: "rig_turn_end" },
      ]) });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /'a' missing/);
    assert.match(r.stderr, /'c' missing/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: last call not rig_turn_end => FAIL", () => {
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", desktop: { checkpoints: [{ name: "built", required: true }] } },
      { dataName: "t.jsonl", dataContent: transcript([
        { tool: "rig_turn_end" },
        { tool: "rig_checkpoint", args: { name: "built" } },
      ]) });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /rig_turn_end/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: must_not_contain hit in transcript => FAIL", () => {
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", validate: { must_not_contain: ["no gate configured"] } },
      { dataName: "t.jsonl", dataContent: transcript([
        { tool: "rig_ask", args: { options: ["a"] }, result: { ok: false, reason: "no gate configured" } },
        { tool: "rig_turn_end" },
      ]) });
    assert.equal(r.code, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: must_contain_in_order against transcript text", () => {
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", validate: { must_contain_in_order: ["rig_checkpoint", "rig_turn_end"] } },
      { dataName: "t.jsonl", dataContent: transcript([
        { tool: "rig_checkpoint", args: { name: "x" } },
        { tool: "rig_turn_end" },
      ]) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: CLI default forbidden markers do NOT apply (no false FAIL on JSON text)", () => {
  const dir = sandbox();
  try {
    // No must_not_contain override; a CLI-default marker ("step_aborted") sits
    // in the transcript args. Desktop default is [] so this must still PASS.
    const r = run(dir, { backend: "desktop" },
      { dataName: "t.jsonl", dataContent: transcript([
        { tool: "rig_ask", args: { options: ["step_aborted"] }, result: { ok: false, reason: "no gate configured" } },
        { tool: "rig_turn_end" },
      ]) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: missing ffprobe / .mov is WARN-only, still PASS", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop" },
      { dataName: "t.jsonl", dataContent: transcript([{ tool: "rig_turn_end" }]),
        movPath: "/nonexistent/recording.mov" });
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stderr, /WARN/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: empty transcript => FAIL (no rig_turn_end)", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop", desktop: { checkpoints: [{ name: "x", required: true }] } },
      { dataName: "t.jsonl", dataContent: "" });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /rig_turn_end/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: MISSING transcript file => FAIL gracefully (no ENOENT crash)", () => {
  const dir = sandbox();
  try {
    const specPath = join(dir, "spec.json");
    writeFileSync(specPath, JSON.stringify({ backend: "desktop" }));
    const r = spawnSync("node", [VALIDATE, specPath, join(dir, "absent.jsonl")], { encoding: "utf8" });
    assert.equal(r.status, 1, "exits 1, not a crash");
    assert.match(r.stderr, /transcript not found/);
    assert.doesNotMatch(r.stderr, /node:fs|ENOENT|at readFileSync/, "no uncaught exception");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: no checkpoints declared + ends rig_turn_end => PASS", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop" },
      { dataName: "t.jsonl", dataContent: transcript([{ tool: "rig_turn_end" }]) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("SKIP_VALIDATE=1 short-circuits the desktop path too", () => {
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", desktop: { checkpoints: [{ name: "never", required: true }] } },
      { dataName: "t.jsonl", dataContent: transcript([{ tool: "rig_checkpoint", args: { name: "x" } }]),
        env: { SKIP_VALIDATE: "1" } });
    assert.equal(r.code, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// --- desktop agent-transcript-tail (CoWork) — audit.jsonl validation (rr-2pp.5.5) ---

test("desktop/cowork: audit.jsonl with a clean result PASSES", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop", surface: "cowork" },
      { dataName: "audit.jsonl", dataContent: audit(AUDIT_OK) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: missing {type:result} FAILS (turn never completed)", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop", surface: "cowork" },
      { dataName: "audit.jsonl", dataContent: audit(AUDIT_OK.filter((e) => e.type !== "result")) });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /no \{type:"result"\} entry/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: result.is_error true FAILS (turn ended in error)", () => {
  const dir = sandbox();
  try {
    const ev = [...AUDIT_OK.slice(0, -1), { type: "result", subtype: "error_max_turns", is_error: true }];
    const r = run(dir, { backend: "desktop", surface: "cowork" },
      { dataName: "audit.jsonl", dataContent: audit(ev) });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /turn ended in error/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: must_contain matches the audit transcript text", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop", surface: "cowork", validate: { must_contain: ["created notes.txt"] } },
      { dataName: "audit.jsonl", dataContent: audit(AUDIT_OK) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: missing must_contain FAILS", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop", surface: "cowork", validate: { must_contain: ["NOPE not present"] } },
      { dataName: "audit.jsonl", dataContent: audit(AUDIT_OK) });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /missing required/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: must_not_contain present FAILS", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop", surface: "cowork", validate: { must_not_contain: ["created notes.txt"] } },
      { dataName: "audit.jsonl", dataContent: audit(AUDIT_OK) });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /forbidden present/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: required checkpoints are NOT enforced here (preflight handles them)", () => {
  // A required checkpoint on a fallback surface is rejected at preflight (5.4),
  // not by validate — so a clean result PASSES even with one declared.
  const dir = sandbox();
  try {
    const r = run(dir,
      { backend: "desktop", surface: "cowork", desktop: { checkpoints: [{ name: "built", required: true }] } },
      { dataName: "audit.jsonl", dataContent: audit(AUDIT_OK) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop: explicit coordination override routes to the audit reader", () => {
  // surface=chat is normally mcp-bridge, but an explicit coordination wins.
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop", surface: "chat", coordination: "agent-transcript-tail" },
      { dataName: "audit.jsonl", dataContent: audit(AUDIT_OK) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: missing audit.jsonl FAILS loud", () => {
  const dir = sandbox();
  try {
    const specPath = join(dir, "spec.json");
    writeFileSync(specPath, JSON.stringify({ backend: "desktop", surface: "cowork" }));
    const r = spawnSync("node", [VALIDATE, specPath, join(dir, "absent-audit.jsonl")], { encoding: "utf8" });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /agent transcript not found/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: must_contain_in_order against the audit transcript text", () => {
  const dir = sandbox();
  try {
    const r = run(dir, { backend: "desktop", surface: "cowork", validate: { must_contain_in_order: ["tool_use", "result"] } },
      { dataName: "audit.jsonl", dataContent: audit(AUDIT_OK) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("desktop/cowork: the LAST {type:result} decides (a later success after an early error PASSES)", () => {
  const dir = sandbox();
  try {
    const ev = [
      { type: "result", subtype: "error_partial", is_error: true },
      { type: "assistant", message: { content: [{ type: "text", text: "retrying" }] } },
      { type: "result", subtype: "success", is_error: false, result: "ok" },
    ];
    const r = run(dir, { backend: "desktop", surface: "cowork" },
      { dataName: "audit.jsonl", dataContent: audit(ev) });
    assert.equal(r.code, 0, r.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
