#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Validate a recording against required positive signals and forbidden markers.
// Exit 0 on pass, non-zero on fail (the exit code is the GIF render gate).
// SKIP_VALIDATE=1 forces pass.
//
//   CLI backend (default):  validate.mjs <spec.json> <cast.cast>
//   desktop backend:        validate.mjs <spec.json> <transcript.jsonl> [<mov>]
//
// Text modes (under spec.validate), applied to the recording's text corpus —
// the cleaned asciinema cast (CLI) or the raw transcript JSONL (desktop):
//   must_contain:           array of strings, set membership (any order)
//   must_contain_in_order:  array of strings, must appear in given order
//   must_not_contain:       array of strings, none may appear
//
// Desktop has two transcript sources, chosen by the surface's coordination
// provider (mirrors lib/coordination.sh):
//   - mcp-bridge (Chat/Code): the bridge transcript. Every required:true
//     checkpoint (spec.desktop.checkpoints[]) must appear in spec-declared order
//     (matched against rig_checkpoint entries by args.name); the last call must
//     be rig_turn_end.
//   - agent-transcript-tail (CoWork): the Agent-SDK transcript audit.jsonl. The
//     bridge tools are dropped here, so turn-end is the explicit {"type":"result"}
//     line (a clean close requires is_error !== true); required checkpoints are
//     rejected at preflight (rr-2pp.5.4), so only must_* text modes apply.
// An optional .mov is a WARN-only ffprobe sanity check (never gates the GIF).

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const [, , specPath, dataPath, movPath] = process.argv;
if (!specPath || !dataPath) {
  console.error("usage: validate.mjs <spec.json> <cast.cast> | <spec.json> <transcript.jsonl> [<mov>]");
  process.exit(2);
}

if (process.env.SKIP_VALIDATE === "1") {
  console.log("[validate] SKIP_VALIDATE=1, skipping");
  process.exit(0);
}

const spec = JSON.parse(readFileSync(specPath, "utf8"));
const backend = spec.backend ?? "cli";
const must = spec.validate?.must_contain ?? [];
const mustInOrder = spec.validate?.must_contain_in_order ?? [];
// The CLI defaults are terminal-output failure markers; they do not map to the
// desktop transcript's structured JSON (which never contains rendered agent
// text), so matching them there risks a false FAIL on a prompt/arg substring.
// Desktop opts into forbidden markers explicitly (default none).
const mustNot = spec.validate?.must_not_contain ?? (backend === "desktop" ? [] : [
  "step_aborted",
  "failure_reason",
]);

// Strip ANSI/CSI/OSC escapes, then APPLY backspaces (they delete the
// preceding character — without this, "ERROR<BS><BS><BS><BS><BS>CLEAR"
// would leave "ERROR" present and false-fail must_not_contain).
// Pragmatic, not a full emulator: handles colours, cursor positioning,
// alternate-screen toggles, CRs, BS char-deletion. Does NOT replay
// cursor movements or wraparound (documented in design.md).
function cleanCast(s) {
  const escStripped = s
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")           // CSI
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "") // OSC
    .replace(/\x1b[@-_]/g, "")                          // single-char ESC
    .replace(/\x1b./g, "")                              // any remaining ESC seq
    .replace(/\r/g, "");
  // Apply \x08 (backspace) destructively: each BS removes the preceding char.
  const out = [];
  for (const ch of escStripped) {
    if (ch === "\x08") {
      if (out.length > 0) out.pop();
    } else {
      out.push(ch);
    }
  }
  // Strip remaining low control chars (preserve \t=09 and \n=0a).
  return out.join("").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "");
}

// Desktop coordination provider for one surface — mirrors lib/coordination.sh
// coordination_provider_for_surface (the RDR-locked map): an explicit
// spec.coordination wins; otherwise cowork -> agent-transcript-tail, chat/code ->
// mcp-bridge.
function providerFor(surface, coordination) {
  const explicit = coordination ?? "auto";
  if (explicit && explicit !== "auto") return explicit;
  if (surface === "cowork") return "agent-transcript-tail";
  // chat/code -> mcp-bridge. An unrecognized surface defaults to mcp-bridge:
  // acceptable because record.sh's preflight resolves+validates the surface via
  // coordination_provider_for_surface (which fails loud) before launch. But warn
  // here so a spec that somehow reaches the validator with a bad surface is not
  // silently bridge-validated — and so this map can't silently drift from the
  // bash one without a signal.
  if (surface !== "chat" && surface !== "code") {
    console.error(`[validate] WARN: unrecognized surface '${surface}' — defaulting to mcp-bridge validation`);
  }
  return "mcp-bridge";
}

// Does this (possibly multi-surface) spec use the bridge for ANY step? Mirrors
// record.sh's USED_BRIDGE (rr-u07): if so, the bridge transcript is the validate
// target — it carries those steps' checkpoints + rig_turn_end (e.g. the Code/Chat
// steps of the tier demo). Only when EVERY step is agent-transcript-tail do we
// validate the audit.jsonl. The surface list comes from steps[] when present,
// else the single legacy top-level surface.
function desktopUsesBridge(s) {
  const surfaces = (Array.isArray(s.steps) && s.steps.length > 0)
    ? s.steps.map((st) => st.surface ?? "chat")
    : [s.surface ?? "chat"];
  return surfaces.some((surface) => providerFor(surface, s.coordination) === "mcp-bridge");
}

// mcp-bridge surfaces (Chat / Code): the bridge transcript is NDJSON, one
// {ts,tool,args,result,session} per call (bridge/server.js). Structured JSON, so
// NO cleanCast — sidesteps the ghost-text gotcha. A MISSING transcript means the
// bridge was never reached. Returns the text corpus; pushes hard failures
// (missing/out-of-order checkpoints, missing turn-end) onto extraFailures.
function validateBridgeTranscript(dataPath, spec, extraFailures) {
  let raw;
  try {
    raw = readFileSync(dataPath, "utf8");
  } catch {
    console.error("[validate] FAILED");
    console.error(`  desktop: transcript not found at ${dataPath} — the bridge was never reached`);
    console.error("           (the model called no rig_* tools: check the .mcpb is enabled in Claude-Rig and loaded before the prompt submits)");
    process.exit(1);
  }
  const lines = raw.split(/\r?\n/).filter((l) => l.trim());
  const entries = [];
  for (const ln of lines) {
    try {
      entries.push(JSON.parse(ln));
    } catch {
      /* tolerate a malformed trailing line */
    }
  }

  // Every required checkpoint must appear, in spec-declared order. Checkpoints
  // are rig_checkpoint entries keyed by args.name (the name the bridge writes as
  // the /tmp/${SESSION}.checkpoint content).
  const required = (spec.desktop?.checkpoints ?? [])
    .filter((c) => c.required)
    .map((c) => c.name);
  const seen = entries
    .filter((e) => e.tool === "rig_checkpoint")
    .map((e) => e.args?.name);
  const seenSet = new Set(seen);
  // Report ALL missing checkpoints (not just the first) — clearer for debugging
  // a multi-checkpoint spec.
  for (const name of required) {
    if (!seenSet.has(name)) extraFailures.push(`required checkpoint '${name}' missing`);
  }
  // Among present required checkpoints, verify spec-declared order via a
  // monotonic cursor; a present-but-too-early checkpoint is out of order.
  let cursor = 0;
  for (const name of required) {
    if (!seenSet.has(name)) continue;
    const idx = seen.indexOf(name, cursor);
    if (idx === -1) extraFailures.push(`required checkpoint '${name}' out of order`);
    else cursor = idx + 1;
  }

  // The last call must be rig_turn_end (the turn closed cleanly).
  const last = entries[entries.length - 1];
  if (!last || last.tool !== "rig_turn_end") {
    extraFailures.push(`last transcript call must be rig_turn_end (was '${last?.tool ?? "none"}')`);
  }
  return lines.join("\n");
}

// agent-transcript-tail surfaces (CoWork, + Code recovery): the bridge tools are
// dropped on CoWork (the remoteMcpServersConfig race), so rig_checkpoint /
// rig_turn_end never appear. Validate against the host-side Claude-Agent-SDK
// transcript audit.jsonl (RDR-001 §Technical Design, amended 2026-05-25), whose
// explicit {"type":"result"} line is the turn-end. dataPath is that audit.jsonl.
// Required checkpoints are rejected at preflight for this provider
// (rr-2pp.5.4 coordination_preflight_gates), so none are enforced here; the
// must_* text assertions carry CoWork's validation.
function validateAgentTranscript(dataPath, extraFailures) {
  let raw;
  try {
    raw = readFileSync(dataPath, "utf8");
  } catch {
    console.error("[validate] FAILED");
    console.error(`  desktop: agent transcript not found at ${dataPath} — no audit.jsonl (the turn never ran)`);
    process.exit(1);
  }
  const lines = raw.split(/\r?\n/).filter((l) => l.trim());
  const entries = [];
  for (const ln of lines) {
    try {
      entries.push(JSON.parse(ln));
    } catch {
      /* tolerate a malformed trailing line */
    }
  }
  // Turn-end = the last {"type":"result"} entry; a clean close requires a falsy
  // is_error (false/absent). Truthy is treated as an errored turn (defensive vs
  // a non-boolean), which is the safe direction for a turn-end gate.
  const result = entries.filter((e) => e?.type === "result").pop();
  if (!result) {
    extraFailures.push(`no {type:"result"} entry in audit.jsonl — the turn never completed`);
  } else if (result.is_error) {
    extraFailures.push(
      `turn ended in error (result.is_error=true${result.subtype ? `, subtype='${result.subtype}'` : ""})`,
    );
  }
  return lines.join("\n");
}

// `text` is the corpus the must_* assertions run against; `extraFailures`
// holds backend-specific hard failures (desktop checkpoint / turn-end).
let text;
const extraFailures = [];

if (backend === "desktop") {
  // Pick how to read the transcript at dataPath from the surface's coordination
  // provider: mcp-bridge surfaces (Chat/Code) produce the bridge transcript;
  // agent-transcript-tail (CoWork) produces the Agent-SDK audit.jsonl.
  text = desktopUsesBridge(spec)
    ? validateBridgeTranscript(dataPath, spec, extraFailures)
    : validateAgentTranscript(dataPath, extraFailures);

  // Optional .mov sanity — WARN only, never gates the GIF (the bead is explicit).
  if (movPath) {
    try {
      const out = execFileSync(
        "ffprobe",
        ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", movPath],
        { encoding: "utf8" },
      ).trim();
      if (!(parseFloat(out) > 0)) {
        console.error(`[validate] WARN: .mov duration is '${out || "unknown"}' (capture may be empty)`);
      }
    } catch (e) {
      console.error(`[validate] WARN: ffprobe .mov sanity check skipped (${e.code ?? e.message})`);
    }
  }
} else {
  // CLI: asciinema cast v2 — header line 1, remaining lines are [time,"o","text"].
  const raw = readFileSync(dataPath, "utf8").split(/\r?\n/);
  let output = "";
  for (let i = 1; i < raw.length; i++) {
    const line = raw[i].trim();
    if (!line) continue;
    try {
      const ev = JSON.parse(line);
      if (Array.isArray(ev) && ev[1] === "o") output += ev[2];
    } catch {
      /* tolerate malformed trailing lines */
    }
  }
  text = cleanCast(output);
}

const missing = must.filter((s) => !text.includes(s));
const present = mustNot.filter((s) => text.includes(s));

let orderViolation = null;
if (mustInOrder.length > 0) {
  // Cursor semantics: each needle must START strictly after the previous
  // needle's START position. This permits overlapping needles (e.g.
  // ["ab","bc"] in "abc") while still enforcing order.
  let cursor = 0;
  for (const needle of mustInOrder) {
    const idx = text.indexOf(needle, cursor);
    if (idx === -1) {
      orderViolation = `'${needle}' missing or out of order after position ${cursor}`;
      break;
    }
    cursor = idx + 1;
  }
}

if (missing.length || present.length || orderViolation || extraFailures.length) {
  console.error("[validate] FAILED");
  if (missing.length) console.error("  missing required:", missing);
  if (present.length) console.error("  forbidden present:", present);
  if (orderViolation) console.error("  order violation:", orderViolation);
  for (const f of extraFailures) console.error("  desktop:", f);
  process.exit(1);
}

console.log("[validate] PASSED");
