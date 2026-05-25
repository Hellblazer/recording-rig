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
// the cleaned asciinema cast (CLI) or the raw bridge transcript JSONL (desktop):
//   must_contain:           array of strings, set membership (any order)
//   must_contain_in_order:  array of strings, must appear in given order
//   must_not_contain:       array of strings, none may appear
//
// Desktop adds (spec.desktop.checkpoints[] of {name, required}):
//   - every required:true checkpoint must appear, in spec-declared order
//     (matched against rig_checkpoint transcript entries by args.name)
//   - the last transcript call must be rig_turn_end
//   - an optional .mov is a WARN-only ffprobe sanity check (never gates the GIF)

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

// `text` is the corpus the must_* assertions run against; `extraFailures`
// holds backend-specific hard failures (desktop checkpoint / turn-end).
let text;
const extraFailures = [];

if (backend === "desktop") {
  // Primary input is the bridge transcript: NDJSON, one {ts,tool,args,result,
  // session} per call (bridge/server.js). Structured JSON, so NO cleanCast —
  // this sidesteps the "not a terminal emulator" ghost-text gotcha.
  const lines = readFileSync(dataPath, "utf8").split(/\r?\n/).filter((l) => l.trim());
  const entries = [];
  for (const ln of lines) {
    try {
      entries.push(JSON.parse(ln));
    } catch {
      /* tolerate a malformed trailing line */
    }
  }
  text = lines.join("\n");

  // Every required checkpoint must appear, in spec-declared order. Checkpoints
  // are rig_checkpoint transcript entries keyed by args.name (the same name the
  // bridge writes as the /tmp/${SESSION}.checkpoint content).
  const required = (spec.desktop?.checkpoints ?? [])
    .filter((c) => c.required)
    .map((c) => c.name);
  const seen = entries
    .filter((e) => e.tool === "rig_checkpoint")
    .map((e) => e.args?.name);
  let cursor = 0;
  for (const name of required) {
    const idx = seen.indexOf(name, cursor);
    if (idx === -1) {
      extraFailures.push(`required checkpoint '${name}' missing or out of order`);
      break;
    }
    cursor = idx + 1;
  }

  // The last call must be rig_turn_end (the turn closed cleanly).
  const last = entries[entries.length - 1];
  if (!last || last.tool !== "rig_turn_end") {
    extraFailures.push(`last transcript call must be rig_turn_end (was '${last?.tool ?? "none"}')`);
  }

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
