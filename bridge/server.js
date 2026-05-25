#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// recording-rig-bridge MCP server — RDR-001 Phase 1 Step 1 (rr-2pp.2.1).
//
// SKELETON: declares the four rig_* coordination tools and dispatches them
// over line-delimited JSON-RPC 2.0 (stdio), returning the RDR-pinned stub
// result shapes. Sentinel writes (rr-2pp.2.2), session resolution +
// rig-config.json gate answers (rr-2pp.2.3) are NOT implemented here — the
// handlers are deliberate stubs. Pure Node stdlib, zero dependencies; mirrors
// probes/recording-rig-probe/server.js.
//
// Tool names use underscores (rig_turn_end, …) rather than the RDR's prose
// form (rig.turn_end): dotted names collide with Claude's tool-namespacing
// (observed in RDR-001 P0.1, where the probe shipped as probe_distinctive_
// marker_42). The dotted forms remain documentation-only.

const { writeFileSync, renameSync, appendFileSync } = require("node:fs");

const SERVER_NAME = "recording-rig-bridge";
const SERVER_VERSION = "0.0.1";
const FALLBACK_PROTOCOL = "2025-06-18";

// Identifier guard — inline port of lib/sentinels.sh:12 rig_check_identifier
// (default regex ^[A-Za-z0-9._-]+$). Defense in depth: record.sh:104-107
// preflights spec-provided names, but the bridge receives tool args at runtime
// independently, so it re-validates anything that becomes a path suffix.
const SENTINEL_ID_RE = /^[A-Za-z0-9._-]+$/;
function checkIdentifier(value) {
  return typeof value === "string" && value.length > 0 && SENTINEL_ID_RE.test(value);
}

function sentinelPath(session, suffix) {
  return "/tmp/" + session + "." + suffix;
}

// Atomic sentinel write — port of render-hooks.sh:31-44: write a .partial
// sibling, then rename(2) it onto the final path so readers never observe a
// 0-byte / half-written file. /tmp is APFS on the same volume (RDR 001-research-5),
// so the rename is atomic and never EXDEVs — no cross-device fallback needed.
// Marker sentinels pass content "" (byte-identical to the CLI hooks' `touch`);
// content sentinels carry NO trailing newline.
function writeSentinel(session, suffix, content) {
  const finalPath = sentinelPath(session, suffix);
  const partial = finalPath + ".partial";
  writeFileSync(partial, content);
  renameSync(partial, finalPath);
  return finalPath;
}

// Append-only transcript at /tmp/${SESSION}.bridge-transcript.jsonl — one JSON
// object per call, the validator's primary input (RDR §TechDesign). Unlike the
// sentinels, each transcript line DOES end in "\n" (NDJSON). Logged for EVERY
// call (including rig_ask) so coverage is complete and in call order.
function appendTranscript(session, tool, args, result) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    tool,
    args,
    result,
    session,
  }) + "\n";
  appendFileSync(sentinelPath(session, "bridge-transcript.jsonl"), line);
}

// Resolve the active SESSION. rr-2pp.2.2 placeholder: reads RIG_SESSION so the
// pure write/transcript paths are exercisable in isolation. rr-2pp.2.3 replaces
// this body with the /tmp/recording-rig.active-session pointer read (re-read on
// every call, never cached) + orphan-call logging.
function resolveSession() {
  const s = process.env.RIG_SESSION;
  return typeof s === "string" && s.length > 0 ? s : null;
}

const TOOLS = [
  {
    name: "rig_turn_end",
    description: "Signal the end of the current turn (RDR prose: rig.turn_end).",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "rig_checkpoint",
    description: "Mark a named checkpoint (RDR prose: rig.checkpoint).",
    inputSchema: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
      additionalProperties: false,
    },
  },
  {
    name: "rig_ask",
    description: "Request the spec-dictated gate answer (RDR prose: rig.ask).",
    inputSchema: {
      type: "object",
      properties: {
        options: { type: "array", items: { type: "string" } },
        prompt: { type: "string" },
      },
      required: ["options"],
      additionalProperties: false,
    },
  },
  {
    name: "rig_emit",
    description: "Emit an arbitrary named sentinel with an optional payload (RDR prose: rig.emit).",
    inputSchema: {
      type: "object",
      properties: { name: { type: "string" }, payload: { type: "object" } },
      required: ["name"],
      additionalProperties: true,
    },
  },
];

function write(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}
function reply(id, result) {
  write({ jsonrpc: "2.0", id, result });
}
function errorReply(id, code, message) {
  write({ jsonrpc: "2.0", id, error: { code, message } });
}

// Wrap a rig result shape as an MCP tool-call result (JSON text content).
function toolResult(shape) {
  return { content: [{ type: "text", text: JSON.stringify(shape) }], isError: false };
}

const RIG_TOOL_NAMES = ["rig_turn_end", "rig_checkpoint", "rig_emit", "rig_ask"];

// Dispatch a rig_* tool. Returns the inner rig result shape, or null for an
// unknown tool (caller maps that to a JSON-RPC -32602). Side effects per call:
// resolve session → write the tool's sentinel (turn_end/checkpoint/emit) →
// append the transcript line. Idempotent: the .partial+rename overwrites.
function runTool(name, args) {
  if (!RIG_TOOL_NAMES.includes(name)) return null; // unknown tool

  const session = resolveSession();
  if (!session) {
    // rr-2pp.2.2 minimal guard. rr-2pp.2.3 adds the pointer read +
    // /tmp/recording-rig.orphan-calls.jsonl logging. No session → no
    // per-session transcript to append to, so we fail loud and return.
    return { ok: false, reason: "no active session" };
  }

  let result;
  switch (name) {
    case "rig_turn_end":
      writeSentinel(session, "turn-end", "");
      result = { ok: true };
      break;
    case "rig_checkpoint": {
      const cpName = args && args.name;
      if (!checkIdentifier(cpName)) {
        result = { ok: false, reason: "invalid checkpoint name: " + String(cpName) };
        break;
      }
      writeSentinel(session, "checkpoint-" + cpName, "");
      result = { ok: true };
      break;
    }
    case "rig_emit": {
      const emName = args && args.name;
      if (!checkIdentifier(emName)) {
        result = { ok: false, reason: "invalid emit name: " + String(emName) };
        break;
      }
      const payload = args && args.payload;
      writeSentinel(session, emName, payload === undefined ? "" : JSON.stringify(payload));
      result = { ok: true };
      break;
    }
    case "rig_ask": {
      // rr-2pp.2.3 wires real gate answers from /tmp/${SESSION}.rig-config.json
      // and the gate-pending sentinel. 2.2 keeps the skeleton placeholder.
      const options = Array.isArray(args && args.options) ? args.options : [];
      result = { answer_index: 0, answer_value: options[0] };
      break;
    }
  }

  // Every resolved call is logged, including invalid-identifier rejections.
  appendTranscript(session, name, args || {}, result);
  return result;
}

function handle(msg) {
  switch (msg.method) {
    case "initialize": {
      const requested = msg.params && msg.params.protocolVersion;
      reply(msg.id, {
        protocolVersion: typeof requested === "string" ? requested : FALLBACK_PROTOCOL,
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
      return;
    }
    case "notifications/initialized":
    case "initialized":
      return; // notification, no response
    case "tools/list":
      reply(msg.id, { tools: TOOLS });
      return;
    case "tools/call": {
      const name = msg.params && msg.params.name;
      const result = runTool(name, (msg.params && msg.params.arguments) || {});
      if (result === null) {
        errorReply(msg.id, -32602, "unknown tool: " + name);
        return;
      }
      reply(msg.id, toolResult(result));
      return;
    }
    case "ping":
      reply(msg.id, {});
      return;
    default:
      if (msg.id !== undefined && msg.id !== null) {
        errorReply(msg.id, -32601, "method not found: " + msg.method);
      }
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    try {
      handle(JSON.parse(line));
    } catch (e) {
      process.stderr.write("parse-error: " + e.message + "\n");
    }
  }
});
process.stdin.on("end", () => process.exit(0));
