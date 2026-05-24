#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// recording-rig-probe MCP server. RDR-001 Phase 0 (P0.1, P0.2).
// Single tool: probe_distinctive_marker_42 -> fixed marker string.
//
// Line-delimited JSON-RPC 2.0 over stdio per MCP spec.

const MARKER = "RECORDING_RIG_PROBE_DISTINCTIVE_MARKER_42_OK";
const SERVER_NAME = "recording-rig-probe";
const SERVER_VERSION = "0.0.1";
const FALLBACK_PROTOCOL = "2025-06-18";

const TOOLS = [
  {
    name: "probe_distinctive_marker_42",
    description:
      "Returns the fixed string " +
      MARKER +
      ". Used by recording-rig RDR-001 Phase 0 probes to confirm .mcpb tools are reachable from the current surface.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
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

function handle(msg) {
  if (msg.method === "initialize") {
    const requested = msg.params && msg.params.protocolVersion;
    reply(msg.id, {
      protocolVersion: typeof requested === "string" ? requested : FALLBACK_PROTOCOL,
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    });
    return;
  }

  if (msg.method === "notifications/initialized" || msg.method === "initialized") {
    return;
  }

  if (msg.method === "tools/list") {
    reply(msg.id, { tools: TOOLS });
    return;
  }

  if (msg.method === "tools/call") {
    const name = msg.params && msg.params.name;
    if (name !== "probe_distinctive_marker_42") {
      errorReply(msg.id, -32602, "unknown tool: " + name);
      return;
    }
    reply(msg.id, {
      content: [{ type: "text", text: MARKER }],
      isError: false,
    });
    return;
  }

  if (msg.method === "ping") {
    reply(msg.id, {});
    return;
  }

  if (msg.id !== undefined && msg.id !== null) {
    errorReply(msg.id, -32601, "method not found: " + msg.method);
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
