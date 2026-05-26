// SPDX-License-Identifier: MIT
//
// Unit tests for lib/coordination.sh — the CoordinationProvider seam (RDR-001
// Phase 4 Step 2, rr-2pp.5.2). Shell functions are exercised by sourcing
// coordination.sh in a bash subprocess, the same spawnSync pattern
// lib/quality.test.mjs uses.
//
// Providers:
//   mcp-bridge            — Chat + Code; waitTurnEnd wraps sentinel_wait_idle
//                           (the existing turn-end sentinel watch), unchanged.
//   agent-transcript-tail — CoWork (+ Code recovery); waitTurnEnd tails the
//                           per-session Claude-Agent-SDK transcript audit.jsonl
//                           for a {"type":"result"} line. Gates unsupported.
//
// Return-code contract (BOTH providers, mirrors sentinel_wait_idle):
//   0 = turn-end observed   1 = session ceiling exceeded   2 = turn_timeout

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const COORD = join(HERE, "coordination.sh");

// Run bash after `source coordination.sh` (which self-sources sentinels.sh).
// COORD is passed as $1 (not interpolated) so a path with spaces stays intact.
function sh(body, env = {}) {
  return spawnSync("bash", ["-c", `set -eu; source "$1"; ${body}`, "--", COORD], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

function tmp() {
  return mkdtempSync(join(tmpdir(), "rig-coord-"));
}

// Build a synthetic rig-profile local-agent-mode-sessions root with one session
// dir holding the given audit.jsonl content. Returns { root, audit }.
function lamsRoot(auditLines) {
  const root = tmp();
  const sess = join(root, "acct-uuid", "org-uuid", "local_session-uuid");
  mkdirSync(sess, { recursive: true });
  const audit = join(sess, "audit.jsonl");
  writeFileSync(audit, auditLines.length ? auditLines.join("\n") + "\n" : "");
  return { root, audit };
}

const RESULT = JSON.stringify({ type: "result", subtype: "success", is_error: false, num_turns: 3, result: "done" });
const THINK = JSON.stringify({ type: "assistant", message: { content: [{ type: "thinking" }] } });
const TOOL = JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", name: "Write" }] } });

// --- selection map ---

test("coordination_provider_for_surface maps surfaces to the RDR-locked defaults", () => {
  for (const [surface, provider] of [["chat", "mcp-bridge"], ["code", "mcp-bridge"], ["cowork", "agent-transcript-tail"]]) {
    const r = sh(`coordination_provider_for_surface ${surface} auto`);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), provider, `${surface} -> ${provider}`);
  }
});

test("coordination_provider_for_surface honours an explicit override over the map", () => {
  const r = sh(`coordination_provider_for_surface cowork mcp-bridge`);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "mcp-bridge");
});

test("coordination_provider_for_surface fails loud on an unknown surface", () => {
  const r = sh(`coordination_provider_for_surface bogus auto`);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /unknown surface/);
});

// --- gate capability (consumed by 5.4 preflight) ---

test("coordination_supports_gates: yes for mcp-bridge, no for agent-transcript-tail", () => {
  assert.equal(sh(`coordination_supports_gates mcp-bridge`).status, 0, "mcp-bridge supports gates");
  assert.notEqual(sh(`coordination_supports_gates agent-transcript-tail`).status, 0, "transcript-tail has no rig.ask");
});

test("coordination_supports_gates fails loud on an unknown provider", () => {
  const r = sh(`coordination_supports_gates bogus-provider`);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /unknown provider/);
});

// --- spec preflight (rr-2pp.5.4): reject gates/required-checkpoints on fallback ---

function specFile(obj) {
  const dir = tmp();
  const p = join(dir, "spec.json");
  writeFileSync(p, JSON.stringify(obj));
  return p;
}

test("preflight: gate-capable provider (mcp-bridge) passes any spec through", () => {
  const spec = specFile({ gates: [{ answer_index: 1 }], desktop: { checkpoints: [{ name: "c", required: true }] } });
  const r = sh(`coordination_preflight_gates mcp-bridge "${spec}"`);
  assert.equal(r.status, 0, r.stderr);
});

test("preflight: fallback provider rejects a spec with gates[]", () => {
  const spec = specFile({ gates: [{ answer_index: 1 }] });
  const r = sh(`coordination_preflight_gates agent-transcript-tail "${spec}"`);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /gate\(s\).*rig\.ask does not reach/s);
});

test("preflight: fallback provider rejects a spec with a required checkpoint", () => {
  const spec = specFile({ desktop: { checkpoints: [{ name: "compiled", required: true }] } });
  const r = sh(`coordination_preflight_gates agent-transcript-tail "${spec}"`);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /required checkpoint\(s\)/);
});

test("preflight: fallback provider accepts a spec with no gates and only optional checkpoints", () => {
  const spec = specFile({ desktop: { checkpoints: [{ name: "noted", required: false }] } });
  const r = sh(`coordination_preflight_gates agent-transcript-tail "${spec}"`);
  assert.equal(r.status, 0, r.stderr);
});

test("preflight: fallback provider accepts a bare spec (no gates, no checkpoints)", () => {
  const spec = specFile({ surface: "cowork" });
  const r = sh(`coordination_preflight_gates agent-transcript-tail "${spec}"`);
  assert.equal(r.status, 0, r.stderr);
});

test("preflight: fallback provider accepts an empty gates[] array", () => {
  const spec = specFile({ gates: [] });
  const r = sh(`coordination_preflight_gates agent-transcript-tail "${spec}"`);
  assert.equal(r.status, 0, r.stderr);
});

test("preflight: unknown provider is conservative — rejects when gates present, passes when none", () => {
  const gated = specFile({ gates: [{ answer_index: 1 }] });
  assert.equal(sh(`coordination_preflight_gates bogus "${gated}"`).status, 1, "unknown + gates -> reject");
  const bare = specFile({ surface: "cowork" });
  assert.equal(sh(`coordination_preflight_gates bogus "${bare}"`).status, 0, "unknown + no gates -> pass");
});

// --- mcp-bridge provider: passthrough to sentinel_wait_idle ---

test("mcp-bridge waitTurnEnd returns 0 when the turn-end sentinel is idle", () => {
  const session = `rigcoordbridge${process.pid}a`;
  // idle=0 so an existing turn-end (delta>=0) settles immediately; clean up after.
  const r = sh(
    `: > "/tmp/${session}.turn-end"; rc=0; coordination_wait_turn_end mcp-bridge 0 5 30 || rc=$?; rm -f "/tmp/${session}.turn-end"; echo "rc=$rc"`,
    { SESSION: session },
  );
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=0/);
});

test("mcp-bridge waitTurnEnd returns 2 (turn_timeout) when no turn-end appears", () => {
  const session = `rigcoordbridge${process.pid}b`;
  const r = sh(`rc=0; coordination_wait_turn_end mcp-bridge 0 1 30 || rc=$?; echo "rc=$rc"`, { SESSION: session });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=2/);
});

test("mcp-bridge waitTurnEnd returns 1 when the session ceiling is exceeded", () => {
  const session = `rigcoordbridge${process.pid}d`;
  // No turn-end sentinel; large turn_timeout so the session ceiling trips first.
  const r = sh(`rc=0; coordination_wait_turn_end mcp-bridge 0 100 1 || rc=$?; echo "rc=$rc"`, { SESSION: session });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=1/);
});

test("mcp-bridge waitTurnEnd rc is byte-identical to a direct sentinel_wait_idle call", () => {
  const session = `rigcoordbridge${process.pid}c`;
  // Same args, same (absent) sentinel: both must report the same rc (2).
  const r = sh(
    `a=0; coordination_wait_turn_end mcp-bridge 0 1 30 || a=$?; b=0; sentinel_wait_idle 0 1 30 || b=$?; echo "a=$a b=$b"`,
    { SESSION: session },
  );
  assert.equal(r.status, 0, r.stderr);
  const m = r.stdout.match(/a=(\d+) b=(\d+)/);
  assert.ok(m, r.stdout);
  assert.equal(m[1], m[2], "wrapper rc must equal direct sentinel_wait_idle rc");
});

// --- agent-transcript-tail provider: audit.jsonl type:result ---

test("agent-transcript-tail waitTurnEnd returns 0 on a {type:result} line", () => {
  const { root } = lamsRoot([THINK, TOOL, RESULT]);
  // baseline 0 accepts any mtime.
  const r = sh(`rc=0; coordination_wait_turn_end agent-transcript-tail 0 5 30 "${root}" 0 || rc=$?; echo "rc=$rc"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=0/);
  rmSync(root, { recursive: true, force: true });
});

test("agent-transcript-tail tolerates malformed NDJSON lines around the result", () => {
  const { root } = lamsRoot(["this is not json {{{", THINK, "42", RESULT]);
  const r = sh(`rc=0; coordination_wait_turn_end agent-transcript-tail 0 5 30 "${root}" 0 || rc=$?; echo "rc=$rc"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=0/);
  rmSync(root, { recursive: true, force: true });
});

test("agent-transcript-tail returns 2 (turn_timeout) when no result line yet", () => {
  const { root } = lamsRoot([THINK, TOOL]); // mid-turn, no result
  const r = sh(`rc=0; coordination_wait_turn_end agent-transcript-tail 0 1 30 "${root}" 0 || rc=$?; echo "rc=$rc"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=2/);
  rmSync(root, { recursive: true, force: true });
});

test("agent-transcript-tail returns 1 when the session ceiling is exceeded", () => {
  const { root } = lamsRoot([THINK]); // no result; large turn_timeout so the ceiling trips first
  const r = sh(`rc=0; coordination_wait_turn_end agent-transcript-tail 0 100 1 "${root}" 0 || rc=$?; echo "rc=$rc"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=1/);
  rmSync(root, { recursive: true, force: true });
});

test("agent-transcript-tail ignores a STALE prior-run result (mtime < baseline)", () => {
  // A completed prior run's audit.jsonl has a result line, but its mtime is
  // older than the baseline captured at this run's submit -> _coord_newest_audit
  // excludes it, so NO qualifying transcript is found and it is NOT mistaken for
  // this turn's end. With nothing new ever appearing this is a hard miss (rc 3),
  // never a false rc 0. Far-future baseline simulates "file older than baseline".
  const { root } = lamsRoot([RESULT]);
  const r = sh(`rc=0; coordination_wait_turn_end agent-transcript-tail 0 1 30 "${root}" 9999999999 || rc=$?; echo "rc=$rc"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=3/, "stale result excluded -> hard miss, not a false turn-end");
  rmSync(root, { recursive: true, force: true });
});

test("agent-transcript-tail returns 3 (hard miss) when no audit.jsonl ever appears", () => {
  // Distinguishes a hard miss (model never started; no transcript) from a soft
  // miss (transcript grew but no result) so the quality log is not polluted.
  const root = tmp(); // empty root: no session dirs, no audit.jsonl
  const r = sh(`rc=0; coordination_wait_turn_end agent-transcript-tail 0 1 30 "${root}" 0 || rc=$?; echo "rc=$rc"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /rc=3/);
  rmSync(root, { recursive: true, force: true });
});

// --- dispatch hygiene ---

test("coordination_wait_turn_end fails loud on an unknown provider", () => {
  const r = sh(`coordination_wait_turn_end bogus-provider 0 1 30`);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /unknown provider/);
});

test("coordination_ready echoes a baseline epoch for agent-transcript-tail, empty for mcp-bridge", () => {
  const b = sh(`coordination_ready agent-transcript-tail`);
  assert.equal(b.status, 0, b.stderr);
  assert.match(b.stdout.trim(), /^\d{10,}$/, "epoch seconds");
  const m = sh(`coordination_ready mcp-bridge`);
  assert.equal(m.status, 0, m.stderr);
  assert.equal(m.stdout.trim(), "");
});
