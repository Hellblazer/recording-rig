// SPDX-License-Identifier: MIT
//
// recording-rig-bridge tests (RDR-001 Phase 1). Drives bridge/server.js over
// stdio JSON-RPC and asserts the wire contract end to end:
//   2.1  skeleton: initialize echo/downgrade, the four rig_* tools, manifest parity
//   2.2  sentinel writes (atomic .partial+rename) + transcript JSONL
//   2.3  active-session pointer resolution, orphan log, rig-config gate answers
//
// Tests are hermetic: each spawns the server with RIG_TMP pointed at a fresh
// temp dir, so the GLOBAL active-session pointer and orphan log never collide
// across tests and cleanup is a single rmSync. The bridge is a fresh PID per
// call, so cross-call state (gate cursor) is reconstructed from the transcript
// — exercised here by driving two separate server processes against one dir.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync, existsSync, readdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = join(here, "server.js");

// ── hermetic sandbox helpers ───────────────────────────────────────────────
function sandbox() {
  return mkdtempSync(join(tmpdir(), "rig-"));
}
function destroy(dir) {
  rmSync(dir, { recursive: true, force: true });
}
function sp(dir, session, suffix) {
  return join(dir, `${session}.${suffix}`);
}
function pointerPath(dir) {
  return join(dir, "recording-rig.active-session");
}
function orphanPath(dir) {
  return join(dir, "recording-rig.orphan-calls.jsonl");
}
function setActiveSession(dir, session) {
  writeFileSync(pointerPath(dir), session);
}
function writeRigConfig(dir, session, config) {
  writeFileSync(sp(dir, session, "rig-config.json"), JSON.stringify(config));
}

// Spawn the server, write each request as one line, close stdin, collect the
// JSON responses keyed by id. Notifications (no id) produce no response.
// `env` is merged over the inherited environment (e.g. { RIG_TMP }).
function drive(requests, env) {
  return new Promise((resolve, reject) => {
    const child = spawn("node", [SERVER], {
      stdio: ["pipe", "pipe", "pipe"],
      env: env ? { ...process.env, ...env } : process.env,
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", reject);
    child.on("close", () => {
      const byId = {};
      for (const line of out.split("\n")) {
        const t = line.trim();
        if (!t) continue;
        const msg = JSON.parse(t);
        if (msg.id !== undefined && msg.id !== null) byId[msg.id] = msg;
      }
      resolve({ byId, stderr: err });
    });
    for (const r of requests) child.stdin.write(JSON.stringify(r) + "\n");
    child.stdin.end();
  });
}

const RIG_TOOLS = ["rig_ask", "rig_checkpoint", "rig_emit", "rig_turn_end"];

function callResult(msg) {
  // tools/call result wraps the rig shape as JSON text content.
  return JSON.parse(msg.result.content[0].text);
}

// ── 2.1 skeleton: protocol + tool surface (session-independent) ─────────────

test("initialize echoes the client's protocolVersion", async () => {
  const { byId } = await drive([
    { jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "t", version: "0" } } },
  ]);
  assert.equal(byId[1].result.protocolVersion, "2025-11-25");
  assert.ok(byId[1].result.capabilities.tools, "advertises tools capability");
  assert.equal(byId[1].result.serverInfo.name, "recording-rig-bridge");
});

test("initialize falls back to 2025-06-18 when no protocolVersion given", async () => {
  const { byId } = await drive([
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } },
  ]);
  assert.equal(byId[1].result.protocolVersion, "2025-06-18");
});

test("notifications/initialized produces no response", async () => {
  const { byId } = await drive([
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", id: 7, method: "ping" },
  ]);
  assert.ok(!("undefined" in byId));
  assert.deepEqual(byId[7].result, {});
});

test("tools/list returns exactly the four rig_* tools", async () => {
  const { byId } = await drive([{ jsonrpc: "2.0", id: 2, method: "tools/list" }]);
  const names = byId[2].result.tools.map((t) => t.name).sort();
  assert.deepEqual(names, RIG_TOOLS);
  for (const t of byId[2].result.tools) {
    assert.ok(t.description, `${t.name} has a description`);
    assert.equal(t.inputSchema.type, "object");
  }
});

test("unknown tool yields a -32602 error", async () => {
  const { byId } = await drive([
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_nope", arguments: {} } },
  ]);
  assert.equal(byId[1].error.code, -32602);
});

test("unknown method yields a -32601 error", async () => {
  const { byId } = await drive([{ jsonrpc: "2.0", id: 1, method: "bogus/method" }]);
  assert.equal(byId[1].error.code, -32601);
});

test("manifest tools[] names match tools/list", async () => {
  const manifest = JSON.parse(readFileSync(join(here, "manifest.json"), "utf8"));
  const manifestNames = manifest.tools.map((t) => t.name).sort();
  assert.deepEqual(manifestNames, RIG_TOOLS);
});

// ── 2.2 sentinel write (atomic .partial+rename) + transcript JSONL ──────────
//
// Sentinel contract is byte-identical to the CLI rig (render-hooks.sh:31-44 +
// hooks.json.tmpl): markers are 0-byte (touch-equivalent), content sentinels
// carry NO trailing newline. Suffix map (RDR §TechDesign L248): turn_end →
// turn-end, checkpoint(name) → checkpoint-<name>, emit(name) → <name>.

test("rig_turn_end / rig_checkpoint / rig_emit return {ok:true}", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rig_checkpoint", arguments: { name: "built" } } },
      { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "rig_emit", arguments: { name: "answer", payload: { v: 42 } } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    assert.deepEqual(callResult(byId[2]), { ok: true });
    assert.deepEqual(callResult(byId[3]), { ok: true });
  } finally { destroy(dir); }
});

test("rig_turn_end writes a 0-byte turn-end marker (byte-identical to touch)", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    const p = sp(dir, session, "turn-end");
    assert.ok(existsSync(p), "turn-end sentinel exists");
    assert.equal(readFileSync(p, "utf8"), "", "marker carries no content / no trailing newline");
  } finally { destroy(dir); }
});

test("rig_checkpoint writes <session>.checkpoint-<name>", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_checkpoint", arguments: { name: "tests-passed" } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    assert.ok(existsSync(sp(dir, session, "checkpoint-tests-passed")), "checkpoint-<name> sentinel exists");
  } finally { destroy(dir); }
});

test("rig_emit writes <session>.<name> with JSON payload and no trailing newline", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_emit", arguments: { name: "answer", payload: { v: 42 } } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    const body = readFileSync(sp(dir, session, "answer"), "utf8");
    assert.equal(body, JSON.stringify({ v: 42 }), "content is the JSON-encoded payload");
    assert.ok(!body.endsWith("\n"), "sentinel carries no trailing newline");
  } finally { destroy(dir); }
});

test("rig_emit without a payload writes an empty sentinel", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_emit", arguments: { name: "ping" } } },
    ], { RIG_TMP: dir });
    assert.equal(readFileSync(sp(dir, session, "ping"), "utf8"), "");
  } finally { destroy(dir); }
});

test("rig_emit rejects an invalid identifier and writes no sentinel", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_emit", arguments: { name: "../escape" } } },
    ], { RIG_TMP: dir });
    const r = callResult(byId[1]);
    assert.equal(r.ok, false);
    assert.match(r.reason, /invalid/);
    // The transcript is still written (every call is logged); nothing else is.
    const sessionFiles = readdirSync(dir).filter((f) => f.startsWith(`${session}.`));
    assert.deepEqual(sessionFiles, [`${session}.bridge-transcript.jsonl`], "a rejected identifier produces no sentinel file");
  } finally { destroy(dir); }
});

test("every call appends a {ts,tool,args,result,session} line to the transcript", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a", "b"] } } },
    ], { RIG_TMP: dir });
    const raw = readFileSync(sp(dir, session, "bridge-transcript.jsonl"), "utf8");
    assert.ok(raw.endsWith("\n"), "transcript NDJSON lines end in \\n");
    const lines = raw.split("\n").filter(Boolean);
    assert.equal(lines.length, 2, "one line per call, including rig_ask");
    for (const ln of lines) {
      const o = JSON.parse(ln);
      assert.equal(o.session, session);
      assert.equal(typeof o.tool, "string");
      assert.ok("args" in o && "result" in o, "carries args and result");
      assert.match(o.ts, /^\d{4}-\d{2}-\d{2}T.*Z$/, "ts is ISO-8601 UTC");
    }
    assert.equal(JSON.parse(lines[0]).tool, "rig_turn_end");
    assert.equal(JSON.parse(lines[1]).tool, "rig_ask");
  } finally { destroy(dir); }
});

// ── 2.3 session resolution: active-session pointer + orphan log ─────────────

test("an active-session pointer with a trailing newline is trimmed and accepted", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    writeFileSync(pointerPath(dir), `${session}\n`);
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    assert.ok(existsSync(sp(dir, session, "turn-end")), "sentinel written under the trimmed session id");
  } finally { destroy(dir); }
});

test("with no active-session pointer every tool fails loud + logs one orphan line each", async () => {
  const dir = sandbox(); // deliberately no pointer
  try {
    const reqs = [
      { name: "rig_turn_end", arguments: {} },
      { name: "rig_checkpoint", arguments: { name: "x" } },
      { name: "rig_emit", arguments: { name: "x" } },
      { name: "rig_ask", arguments: { options: ["a"] } },
    ].map((params, i) => ({ jsonrpc: "2.0", id: i + 1, method: "tools/call", params }));
    const { byId } = await drive(reqs, { RIG_TMP: dir });
    for (let i = 1; i <= 4; i++) {
      assert.deepEqual(callResult(byId[i]), { ok: false, reason: "no active session" });
    }
    const lines = readFileSync(orphanPath(dir), "utf8").split("\n").filter(Boolean);
    assert.equal(lines.length, 4, "exactly one orphan record per call");
    for (const ln of lines) {
      const o = JSON.parse(ln);
      assert.equal(o.reason, "no active session");
      assert.equal(typeof o.tool, "string");
      assert.ok("args" in o && o.ts, "orphan record carries args + ts");
    }
    // No session-scoped files written — only the global orphan log exists.
    assert.deepEqual(readdirSync(dir), ["recording-rig.orphan-calls.jsonl"]);
  } finally { destroy(dir); }
});

test("a malformed active-session pointer is rejected (fails loud + orphan log)", async () => {
  const dir = sandbox();
  try {
    setActiveSession(dir, "bad session!"); // space + ! fail the identifier regex
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { ok: false, reason: "no active session" });
    assert.equal(readFileSync(orphanPath(dir), "utf8").split("\n").filter(Boolean).length, 1);
  } finally { destroy(dir); }
});

// ── 2.3 rig_ask gate answers (flat gate cursor, mirrors bin/driver.sh) ──────

test("rig_ask returns the configured gate answer (success shape has no ok field)", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    writeRigConfig(dir, session, { session, gates: [{ for_command: 0, answer_index: 1 }] });
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["alpha", "beta"], prompt: "pick" } } },
    ], { RIG_TMP: dir });
    const r = callResult(byId[1]);
    assert.deepEqual(r, { answer_index: 1, answer_value: "beta" });
    assert.ok(!("ok" in r), "success shape carries no ok field");
  } finally { destroy(dir); }
});

test("two gates for the same command are consumed in array order across calls", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    writeRigConfig(dir, session, { session, gates: [
      { for_command: 0, answer_index: 1 },
      { for_command: 0, answer_index: 0 },
    ] });
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a", "b"] } } },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a", "b"] } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { answer_index: 1, answer_value: "b" });
    assert.deepEqual(callResult(byId[2]), { answer_index: 0, answer_value: "a" });
  } finally { destroy(dir); }
});

test("a rig_ask past the last gate fails loud with 'no gate configured'", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    writeRigConfig(dir, session, { session, gates: [{ for_command: 0, answer_index: 0 }] });
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a", "b"] } } },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a", "b"] } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { answer_index: 0, answer_value: "a" });
    assert.deepEqual(callResult(byId[2]), { ok: false, reason: "no gate configured" });
  } finally { destroy(dir); }
});

test("rig_ask with no rig-config fails loud with 'no gate configured'", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a"] } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { ok: false, reason: "no gate configured" });
  } finally { destroy(dir); }
});

test("rig_ask with a corrupt rig-config fails loud with 'no gate configured'", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    writeFileSync(sp(dir, session, "rig-config.json"), "not json{");
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a"] } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(byId[1]), { ok: false, reason: "no gate configured" });
  } finally { destroy(dir); }
});

test("rig-config is re-read each call: mid-session rewrite honored, cursor persists across PIDs", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    // Config A: gate[1] answers 'b'.
    writeRigConfig(dir, session, { session, gates: [
      { for_command: 0, answer_index: 0 },
      { for_command: 0, answer_index: 1 },
    ] });
    const first = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a", "b"] } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(first.byId[1]), { answer_index: 0, answer_value: "a" }, "gate[0]");
    // Rewrite gate[1] → 'a'. A fresh PID must read the new file (not cache),
    // and reconstruct gateIdx=1 from the shared transcript.
    writeRigConfig(dir, session, { session, gates: [
      { for_command: 0, answer_index: 0 },
      { for_command: 0, answer_index: 0 },
    ] });
    const second = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a", "b"] } } },
    ], { RIG_TMP: dir });
    // Cached config A would answer 'b'; the rewritten gate[1] answers 'a'.
    assert.deepEqual(callResult(second.byId[1]), { answer_index: 0, answer_value: "a" }, "gate[1], re-read");
  } finally { destroy(dir); }
});

test("a gate bound to a later command is skipped until that command's turn (for_command boundary)", async () => {
  const dir = sandbox(); const session = "sess";
  try {
    setActiveSession(dir, session);
    writeRigConfig(dir, session, { session, gates: [{ for_command: 1, answer_index: 1 }] });
    // During command 0 (no prior rig_turn_end), the gate targets command 1 → no match.
    const a = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["x", "y"] } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(a.byId[1]), { ok: false, reason: "no gate configured" });
    // End command 0, then ask during command 1: the failed ask did NOT burn the
    // slot (gateIdx still 0), and for_command==1 now matches k==1.
    const b = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["x", "y"] } } },
    ], { RIG_TMP: dir });
    assert.deepEqual(callResult(b.byId[2]), { answer_index: 1, answer_value: "y" });
  } finally { destroy(dir); }
});
