// SPDX-License-Identifier: MIT
//
// rr-2pp.2.1 — bridge skeleton tests (RDR-001 Phase 1 Step 1).
// Written first (TDD). Drives bridge/server.js over stdio JSON-RPC and asserts
// the skeleton contract: initialize protocol echo + downgrade, exactly the four
// rig_* tools, each tool's RDR-pinned stub result shape, manifest/tools parity.
//
// Skeleton scope only: stub returns. Sentinel writes (2.2) and rig-config
// gate answers (2.3) are NOT exercised here.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync, existsSync, readdirSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = join(here, "server.js");

// Unique per-test SESSION id (matches the [A-Za-z0-9._-]+ sentinel regex) so
// concurrent runs never collide on /tmp/<session>.* and cleanup is scoped.
let seq = 0;
function uniqueSession() {
  return `rigtest-${process.pid}-${Date.now()}-${seq++}`;
}
function sentinelPath(session, suffix) {
  return join("/tmp", `${session}.${suffix}`);
}
// Remove every /tmp/<session>.* file this test produced.
function cleanup(session) {
  for (const f of readdirSync("/tmp")) {
    if (f.startsWith(`${session}.`)) {
      try { unlinkSync(join("/tmp", f)); } catch { /* already gone */ }
    }
  }
}

// Spawn the server, write each request as one line, close stdin, collect the
// JSON responses keyed by id. Notifications (no id) produce no response.
// `env` is merged over the inherited environment (e.g. { RIG_SESSION }).
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

test("rig_turn_end / rig_checkpoint / rig_emit return {ok:true}", async () => {
  const session = uniqueSession();
  try {
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rig_checkpoint", arguments: { name: "built" } } },
      { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "rig_emit", arguments: { name: "answer", payload: { v: 42 } } } },
    ], { RIG_SESSION: session });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    assert.deepEqual(callResult(byId[2]), { ok: true });
    assert.deepEqual(callResult(byId[3]), { ok: true });
  } finally { cleanup(session); }
});

test("rig_ask returns an answer_index/answer_value placeholder over options", async () => {
  const session = uniqueSession();
  try {
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "rig_ask", arguments: { options: ["alpha", "beta"], prompt: "pick" } } },
    ], { RIG_SESSION: session });
    const r = callResult(byId[1]);
    assert.equal(typeof r.answer_index, "number");
    assert.equal(r.answer_value, ["alpha", "beta"][r.answer_index]);
  } finally { cleanup(session); }
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

// ── rr-2pp.2.2: sentinel write (atomic .partial+rename) + transcript JSONL ──
//
// Sentinel contract is byte-identical to the CLI rig (render-hooks.sh:31-44 +
// hooks.json.tmpl): markers are 0-byte (touch-equivalent), content sentinels
// carry NO trailing newline. Suffix map (RDR §TechDesign L248): turn_end →
// turn-end, checkpoint(name) → checkpoint-<name>, emit(name) → <name>.

test("rig_turn_end writes a 0-byte turn-end marker (byte-identical to touch)", async () => {
  const session = uniqueSession();
  try {
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
    ], { RIG_SESSION: session });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    const p = sentinelPath(session, "turn-end");
    assert.ok(existsSync(p), "turn-end sentinel exists");
    assert.equal(readFileSync(p, "utf8"), "", "marker carries no content / no trailing newline");
  } finally { cleanup(session); }
});

test("rig_checkpoint writes /tmp/<session>.checkpoint-<name>", async () => {
  const session = uniqueSession();
  try {
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_checkpoint", arguments: { name: "tests-passed" } } },
    ], { RIG_SESSION: session });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    assert.ok(existsSync(sentinelPath(session, "checkpoint-tests-passed")), "checkpoint-<name> sentinel exists");
  } finally { cleanup(session); }
});

test("rig_emit writes /tmp/<session>.<name> with JSON payload and no trailing newline", async () => {
  const session = uniqueSession();
  try {
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_emit", arguments: { name: "answer", payload: { v: 42 } } } },
    ], { RIG_SESSION: session });
    assert.deepEqual(callResult(byId[1]), { ok: true });
    const body = readFileSync(sentinelPath(session, "answer"), "utf8");
    assert.equal(body, JSON.stringify({ v: 42 }), "content is the JSON-encoded payload");
    assert.ok(!body.endsWith("\n"), "sentinel carries no trailing newline");
  } finally { cleanup(session); }
});

test("rig_emit without a payload writes an empty sentinel", async () => {
  const session = uniqueSession();
  try {
    await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_emit", arguments: { name: "ping" } } },
    ], { RIG_SESSION: session });
    assert.equal(readFileSync(sentinelPath(session, "ping"), "utf8"), "");
  } finally { cleanup(session); }
});

test("rig_emit rejects an invalid identifier and writes no sentinel", async () => {
  const session = uniqueSession();
  try {
    const { byId } = await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_emit", arguments: { name: "../escape" } } },
    ], { RIG_SESSION: session });
    const r = callResult(byId[1]);
    assert.equal(r.ok, false);
    assert.match(r.reason, /invalid/);
    // The transcript is still written (every call is logged); nothing else is.
    const leaked = readdirSync("/tmp")
      .filter((f) => f.startsWith(`${session}.`) && f !== `${session}.bridge-transcript.jsonl`);
    assert.deepEqual(leaked, [], "a rejected identifier produces no sentinel file");
  } finally { cleanup(session); }
});

test("every call appends a {ts,tool,args,result,session} line to the transcript", async () => {
  const session = uniqueSession();
  try {
    await drive([
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rig_ask", arguments: { options: ["a", "b"] } } },
    ], { RIG_SESSION: session });
    const raw = readFileSync(sentinelPath(session, "bridge-transcript.jsonl"), "utf8");
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
  } finally { cleanup(session); }
});

test("with no active session a tool call fails loud and writes nothing", async () => {
  // RIG_SESSION explicitly empty: 2.2's placeholder resolver yields no session.
  // (rr-2pp.2.3 replaces this with the active-session pointer + orphan log.)
  const { byId } = await drive([
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
  ], { RIG_SESSION: "" });
  const r = callResult(byId[1]);
  assert.equal(r.ok, false);
  assert.match(r.reason, /no active session/);
});
