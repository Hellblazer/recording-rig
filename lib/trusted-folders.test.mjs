// SPDX-License-Identifier: MIT
//
// Unit tests for lib/trusted-folders.sh — Code-surface trusted-folder
// pre-seeding (RDR-001 Phase 4 Step 3, rr-2pp.5.3). spawnSync-sources the lib in
// bash, the lib/quality.test.mjs pattern.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, "trusted-folders.sh");

function sh(body, env = {}) {
  return spawnSync("bash", ["-c", `set -eu; source "$1"; ${body}`, "--", LIB], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

function tmp() {
  return mkdtempSync(join(tmpdir(), "rig-tf-"));
}

const read = (p) => JSON.parse(readFileSync(p, "utf8"));

test("seeds localAgentModeTrustedFolders into a brand-new (absent) config", () => {
  const cfg = join(tmp(), "nested", "config.json"); // parent dir absent too
  const r = sh(`trusted_folders_seed "${cfg}" /Users/x/proj /Users/x/other`);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(existsSync(cfg));
  assert.deepEqual(read(cfg).localAgentModeTrustedFolders.sort(), ["/Users/x/other", "/Users/x/proj"]);
});

test("preserves every other key in an existing config", () => {
  const dir = tmp();
  const cfg = join(dir, "config.json");
  writeFileSync(cfg, JSON.stringify({ userThemeMode: "dark", "oauth:tokenCache": { a: 1 } }));
  const r = sh(`trusted_folders_seed "${cfg}" /Users/x/proj`);
  assert.equal(r.status, 0, r.stderr);
  const c = read(cfg);
  assert.equal(c.userThemeMode, "dark");
  assert.deepEqual(c["oauth:tokenCache"], { a: 1 });
  assert.deepEqual(c.localAgentModeTrustedFolders, ["/Users/x/proj"]);
});

test("merges with an existing array and de-duplicates (incl. trailing-slash variants)", () => {
  const dir = tmp();
  const cfg = join(dir, "config.json");
  writeFileSync(cfg, JSON.stringify({ localAgentModeTrustedFolders: ["/Users/x/proj"] }));
  // Re-add the same folder with a trailing slash + a new one.
  const r = sh(`trusted_folders_seed "${cfg}" /Users/x/proj/ /Users/x/new`);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(read(cfg).localAgentModeTrustedFolders.sort(), ["/Users/x/new", "/Users/x/proj"]);
});

test("normalizes trailing slashes on the seeded paths", () => {
  const dir = tmp();
  const cfg = join(dir, "config.json");
  const r = sh(`trusted_folders_seed "${cfg}" /Users/x/proj///`);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(read(cfg).localAgentModeTrustedFolders, ["/Users/x/proj"]);
});

test("no folders is a no-op and leaves the config untouched", () => {
  const dir = tmp();
  const cfg = join(dir, "config.json");
  writeFileSync(cfg, JSON.stringify({ userThemeMode: "light" }));
  const before = readFileSync(cfg, "utf8");
  const r = sh(`trusted_folders_seed "${cfg}"`);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(readFileSync(cfg, "utf8"), before, "config unchanged when no folders given");
});

test("result is valid JSON written atomically (no .partial left behind)", () => {
  const dir = tmp();
  const cfg = join(dir, "config.json");
  const r = sh(`trusted_folders_seed "${cfg}" /Users/x/proj`);
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotThrow(() => read(cfg));
  assert.ok(!existsSync(`${cfg}.partial`), "no leftover .partial");
});

test("malformed existing config: fails loud, leaves no .partial, original untouched", () => {
  const dir = tmp();
  const cfg = join(dir, "config.json");
  writeFileSync(cfg, "{ this is not valid json"); // non-empty -> not replaced with {}
  const before = readFileSync(cfg, "utf8");
  const r = sh(`trusted_folders_seed "${cfg}" /Users/x/proj`);
  assert.notEqual(r.status, 0, "jq parse failure must propagate");
  assert.ok(!existsSync(`${cfg}.partial`), "partial cleaned up on failure");
  assert.equal(readFileSync(cfg, "utf8"), before, "original config not clobbered");
});
