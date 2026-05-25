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
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = join(here, "server.js");

// Spawn the server, write each request as one line, close stdin, collect the
// JSON responses keyed by id. Notifications (no id) produce no response.
function drive(requests) {
  return new Promise((resolve, reject) => {
    const child = spawn("node", [SERVER], { stdio: ["pipe", "pipe", "pipe"] });
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
  const { byId } = await drive([
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rig_turn_end", arguments: {} } },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rig_checkpoint", arguments: { name: "built" } } },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "rig_emit", arguments: { name: "answer", payload: { v: 42 } } } },
  ]);
  assert.deepEqual(callResult(byId[1]), { ok: true });
  assert.deepEqual(callResult(byId[2]), { ok: true });
  assert.deepEqual(callResult(byId[3]), { ok: true });
});

test("rig_ask returns an answer_index/answer_value placeholder over options", async () => {
  const { byId } = await drive([
    { jsonrpc: "2.0", id: 1, method: "tools/call",
      params: { name: "rig_ask", arguments: { options: ["alpha", "beta"], prompt: "pick" } } },
  ]);
  const r = callResult(byId[1]);
  assert.equal(typeof r.answer_index, "number");
  assert.equal(r.answer_value, ["alpha", "beta"][r.answer_index]);
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
