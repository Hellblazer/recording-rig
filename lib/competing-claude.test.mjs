// SPDX-License-Identifier: MIT
//
// Unit tests for lib/competing-claude.sh — rr-re6 competing-Claude.app detection.
// A competing Claude.app bundle instance steals macOS activation, leaving the
// freshly-launched Claude-Rig instance backgrounded so its Chromium a11y tree
// never materializes (the driver's armWait then times out). The guard refuses to
// record while one is running. This tests the PURE decision fn: it reads
// `pid command...` lines on stdin + takes the Rig user-data-dir, and emits the
// pids of Claude.app MAINS (not --type= helpers) whose --user-data-dir is NOT the
// Rig dir (absent = the default/primary profile = competing). spawnSync-sources
// the lib in bash, the lib/trusted-folders.test.mjs precedent.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, "competing-claude.sh");
const CLAUDE = "/Applications/Claude.app/Contents/MacOS/Claude";

// Feed `stdin` to `competing_claude_pids "<rigDir>"` and return the emitted pids.
function pids(stdin, rigDir) {
  const r = spawnSync(
    "bash",
    ["-c", `set -eu; source "$1"; competing_claude_pids "$2"`, "--", LIB, rigDir],
    { encoding: "utf8", input: stdin },
  );
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
}

test("rig-only main is clean (the instance record.sh is about to launch)", () => {
  const stdin = `111 ${CLAUDE} --user-data-dir=/rig --force-renderer-accessibility\n`;
  assert.deepEqual(pids(stdin, "/rig"), []);
});

test("primary main with NO --user-data-dir (default profile) is competing", () => {
  assert.deepEqual(pids(`222 ${CLAUDE}\n`, "/rig"), ["222"]);
});

test("a main with a DIFFERENT --user-data-dir is competing", () => {
  const stdin = `333 ${CLAUDE} --user-data-dir=/other\n`;
  assert.deepEqual(pids(stdin, "/rig"), ["333"]);
});

test("--type= helper processes are ignored (only mains steal activation)", () => {
  // A non-rig helper: --type= present, so it is a renderer/GPU child, not a main.
  const stdin = `444 ${CLAUDE} --type=renderer --user-data-dir=/other\n`;
  assert.deepEqual(pids(stdin, "/rig"), []);
});

test("mixed roster with a space-bearing rig dir: only the competing main(s)", () => {
  const rig = "/Users/x/Library/Application Support/Claude-Rig";
  const stdin = [
    `10 /usr/bin/node /some/server.js`, // not Claude at all -> ignored
    `20 ${CLAUDE} --user-data-dir=${rig} --force-renderer-accessibility`, // the rig main -> clean
    `30 ${CLAUDE} --type=gpu-process --user-data-dir=${rig}`, // rig helper -> ignored
    `40 ${CLAUDE}`, // the user's primary main -> COMPETING
    ``,
  ].join("\n");
  assert.deepEqual(pids(stdin, rig), ["40"]);
});

test("empty input is no competing pids, rc 0", () => {
  assert.deepEqual(pids(``, "/rig"), []);
});

test("rig-dir prefix boundary: /rig-other is NOT the rig dir (competing)", () => {
  // Guards against a naive substring match treating /rig-other as the rig dir.
  const stdin = `555 ${CLAUDE} --user-data-dir=/rig-other\n`;
  assert.deepEqual(pids(stdin, "/rig"), ["555"]);
});

test("a non-Claude process with the marker only in a LATER arg is ignored", () => {
  // A grep/editor/script whose argv embeds the Claude path (even with a competing
  // --user-data-dir) but whose executable (argv[0]) is NOT Claude must not match —
  // the marker is matched at argv[0] only, not anywhere in the command line.
  const stdin = `777 /bin/bash -c : ${CLAUDE} --user-data-dir=/other\n`;
  assert.deepEqual(pids(stdin, "/rig"), []);
});
