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

const SERVER_NAME = "recording-rig-bridge";
const SERVER_VERSION = "0.0.1";
const FALLBACK_PROTOCOL = "2025-06-18";

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

// SKELETON stub handlers — RDR-pinned shapes; wiring (sentinel write, session
// resolution, rig-config gate read) is deferred to rr-2pp.2.2 / 2.3.
function callTool(name, args) {
  switch (name) {
    case "rig_turn_end":
      return toolResult({ ok: true });
    case "rig_checkpoint":
      return toolResult({ ok: true });
    case "rig_emit":
      return toolResult({ ok: true });
    case "rig_ask": {
      const options = Array.isArray(args && args.options) ? args.options : [];
      // Placeholder: real gate answers come from /tmp/${SESSION}.rig-config.json (rr-2pp.2.3).
      return toolResult({ answer_index: 0, answer_value: options[0] });
    }
    default:
      return null; // unknown tool
  }
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
      const result = callTool(name, (msg.params && msg.params.arguments) || {});
      if (result === null) {
        errorReply(msg.id, -32602, "unknown tool: " + name);
        return;
      }
      reply(msg.id, result);
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
