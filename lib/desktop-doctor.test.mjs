// SPDX-License-Identifier: MIT
//
// Unit tests for lib/desktop-doctor.sh — Desktop-backend doctor checks +
// subcommand dispatch (RDR-001 Phase 5 Step 1, rr-2pp.6.1.2 / rr-zgh).
// spawnSync-sources the lib in bash with stubbed ok/warn/hint + mocked
// env/PATH/fixtures, the lib/trusted-folders.test.mjs pattern.
//
// The lib's checks call ok/warn/hint (provided by bin/doctor.sh at runtime); the
// STUBS below stand in for them and echo a parseable prefix so assertions can
// distinguish a pass (OK:) from an advisory (WARN:) and read the hint text.
// All Desktop checks are advisory (WARN, never bad) — these tests assert the
// classification, not a failure.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, chmodSync, utimesSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, "desktop-doctor.sh");

// Stand-ins for the reporter helpers doctor.sh injects. Defined AFTER the lib is
// sourced (the lib only DEFINES functions at source time; ok/warn/hint resolve
// at call time), so these win.
const STUBS = `ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; hint(){ echo "HINT:$*"; };`;

// No `set -e`: several lib functions intentionally return non-zero (cache stale,
// unknown subcommand) and the tests capture those via `if`/`$?`.
function sh(body, env = {}) {
  return spawnSync("bash", ["-c", `set -u; source "$1"; ${STUBS} ${body}`, "--", LIB], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

const tmp = () => mkdtempSync(join(tmpdir(), "rig-dd-"));
const lines = (s) => s.split("\n").filter(Boolean);

function stubPerms(dir, json) {
  const p = join(dir, "perms-check");
  writeFileSync(p, `#!/usr/bin/env bash\necho '${json}'\n`);
  chmodSync(p, 0o755);
  return p;
}

test("_desktop_cache_fresh: 0 for a fresh file, 1 for stale, 1 for absent", () => {
  const dir = tmp();
  const fresh = join(dir, "fresh");
  writeFileSync(fresh, "x");
  const stale = join(dir, "stale");
  writeFileSync(stale, "x");
  const old = new Date(Date.now() - 40 * 86400 * 1000); // 40 days ago
  utimesSync(stale, old, old);
  const r = sh(`
    if _desktop_cache_fresh "${fresh}" 30; then echo FRESH; else echo STALE; fi
    if _desktop_cache_fresh "${stale}" 30; then echo FRESH; else echo STALE; fi
    if _desktop_cache_fresh "${join(dir, "absent")}" 30; then echo FRESH; else echo STALE; fi
  `);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(lines(r.stdout), ["FRESH", "STALE", "STALE"]);
});

test("_desktop_doctor_dispatch routes each subcommand to its handler with args", () => {
  const handlers = {
    "--install-bridge": "desktop_install_bridge",
    "--install-profile": "desktop_install_profile",
    "--seed-from-primary": "desktop_seed_from_primary",
    "--probe-surfaces": "desktop_probe_surfaces",
    "--verify-bridge": "desktop_verify_bridge",
  };
  for (const [flag, fn] of Object.entries(handlers)) {
    const r = sh(`${fn}(){ echo "CALLED:${fn}:$*"; }; _desktop_doctor_dispatch ${flag} extra`);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, new RegExp(`CALLED:${fn}:extra`));
  }
});

test("_desktop_doctor_dispatch: unknown subcommand returns 2 and lists the valid ones", () => {
  const r = sh(`_desktop_doctor_dispatch --bogus; echo "RC:$?"`);
  assert.match(r.stdout, /RC:2/);
  assert.match(r.stderr, /unknown subcommand '--bogus'/);
  assert.match(r.stderr, /--install-bridge/);
});

test("_desktop_check_perms: accessibility ok, screen-recording warn + exact pane hint", () => {
  const dir = tmp();
  stubPerms(dir, '{"accessibility":true,"screenRecording":false}');
  const r = sh(`_desktop_check_perms`, { RIG_PERMS_CHECK: join(dir, "perms-check") });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /OK:Accessibility permission granted/);
  assert.match(r.stdout, /WARN:Screen Recording permission NOT granted/);
  assert.match(r.stdout, /HINT:.*System Settings > Privacy & Security > Screen Recording/);
});

test("_desktop_check_perms: both granted -> two oks, no warn", () => {
  const dir = tmp();
  stubPerms(dir, '{"accessibility":true,"screenRecording":true}');
  const r = sh(`_desktop_check_perms`, { RIG_PERMS_CHECK: join(dir, "perms-check") });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /OK:Accessibility permission granted/);
  assert.match(r.stdout, /OK:Screen Recording permission granted/);
  assert.doesNotMatch(r.stdout, /WARN:/);
});

test("_desktop_check_perms: missing perms-check binary -> warn + build hint", () => {
  const r = sh(`_desktop_check_perms`, { RIG_PERMS_CHECK: "/nonexistent/perms-check" });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /WARN:perms-check not built/);
  assert.match(r.stdout, /HINT:.*build-perms-check\.sh/);
});

test("_desktop_check_bridge: enabled -> ok; disabled -> warn; absent -> warn + install hint", () => {
  const dir = tmp();
  const enabled = join(dir, "enabled.json");
  writeFileSync(enabled, '{"isEnabled":true}');
  const disabled = join(dir, "disabled.json");
  writeFileSync(disabled, '{"isEnabled":false}');

  let r = sh(`_desktop_check_bridge`, { RIG_BRIDGE_SETTINGS: enabled });
  assert.match(r.stdout, /OK:recording-rig-bridge installed and enabled/);

  r = sh(`_desktop_check_bridge`, { RIG_BRIDGE_SETTINGS: disabled });
  assert.match(r.stdout, /WARN:recording-rig-bridge installed but DISABLED/);

  r = sh(`_desktop_check_bridge`, { RIG_BRIDGE_SETTINGS: join(dir, "nope.json") });
  assert.match(r.stdout, /WARN:recording-rig-bridge not installed/);
  assert.match(r.stdout, /HINT:.*--install-bridge/);
});

test("_desktop_check_caches: absent caches warn and point at --probe-surfaces", () => {
  const dir = tmp();
  const r = sh(`_desktop_check_caches`, {
    RIG_SELECTOR_CACHE: join(dir, "sel.json"),
    RIG_PROBE_CACHE: join(dir, "probe.json"),
  });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /WARN:AX-selector probe cache absent/);
  assert.match(r.stdout, /WARN:surface MCP-probe cache absent/);
  assert.match(r.stdout, /HINT:.*--probe-surfaces/);
});

test("desktop_doctor_checks runs end-to-end without invoking any mutating subcommand", () => {
  const dir = tmp();
  const pdir = tmp();
  stubPerms(pdir, '{"accessibility":true,"screenRecording":true}');
  const sentinel = join(dir, "SIDE_EFFECT");
  const r = sh(
    `
    desktop_install_bridge(){ touch "${sentinel}"; };
    desktop_install_profile(){ touch "${sentinel}"; };
    desktop_seed_from_primary(){ touch "${sentinel}"; };
    desktop_probe_surfaces(){ touch "${sentinel}"; };
    desktop_verify_bridge(){ touch "${sentinel}"; };
    desktop_doctor_checks; echo "RC:$?"
  `,
    {
      CLAUDE_RIG_DIR: join(dir, "profile"),
      RIG_PERMS_CHECK: join(pdir, "perms-check"),
      RIG_BRIDGE_SETTINGS: join(dir, "bridge.json"),
      RIG_SELECTOR_CACHE: join(dir, "sel.json"),
      RIG_PROBE_CACHE: join(dir, "probe.json"),
      RIG_CLAUDE_APP: join(dir, "Claude.app"),
      RIG_QUALITY_LOG: join(dir, "quality.jsonl"),
    },
  );
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /RC:0/);
  assert.ok(!existsSync(sentinel), "no mutating subcommand was invoked by the checks path");
});

// --- rr-5kf: --install-bridge ---

const readJSON = (p) => JSON.parse(readFileSync(p, "utf8"));

// Build a minimal .mcpb (a zip with junked paths — manifest.json + server.js at
// the root, matching bridge/recording-rig-bridge.mcpb's structure).
function makeMcpb(dir, files) {
  const src = join(dir, "src");
  mkdirSync(src, { recursive: true });
  const names = Object.keys(files);
  for (const n of names) writeFileSync(join(src, n), files[n]);
  const mcpb = join(dir, "bundle.mcpb");
  const r = spawnSync("zip", ["-q", "-j", mcpb, ...names.map((n) => join(src, n))], { encoding: "utf8" });
  if (r.status !== 0) throw new Error("zip fixture failed: " + r.stderr);
  return mcpb;
}

test("_desktop_bridge_enable: merges isEnabled:true, preserving existing keys", () => {
  const dir = tmp();
  const settings = join(dir, "bridge.json");
  writeFileSync(settings, JSON.stringify({ someOtherKey: "keep", isEnabled: false }));
  const r = sh(`_desktop_bridge_enable "${settings}"`);
  assert.equal(r.status, 0, r.stderr);
  const c = readJSON(settings);
  assert.equal(c.isEnabled, true);
  assert.equal(c.someOtherKey, "keep", "other keys preserved (no clobber)");
});

test("_desktop_bridge_enable: writes isEnabled:true into an absent settings file", () => {
  const dir = tmp();
  const settings = join(dir, "nested", "bridge.json"); // parent dir absent too
  const r = sh(`_desktop_bridge_enable "${settings}"`);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(readJSON(settings), { isEnabled: true });
});

test("_desktop_bridge_enable: malformed settings fails loud, leaves no .partial, original intact", () => {
  const dir = tmp();
  const settings = join(dir, "bridge.json");
  writeFileSync(settings, "{ not valid json");
  const before = readFileSync(settings, "utf8");
  const r = sh(`_desktop_bridge_enable "${settings}"; echo "RC:$?"`);
  assert.match(r.stdout, /RC:1\b/); // \b so a 127 "command not found" cannot pass spuriously
  assert.ok(!existsSync(`${settings}.partial`), "no leftover .partial");
  assert.equal(readFileSync(settings, "utf8"), before, "original not clobbered");
});

test("_desktop_bridge_install_bundle: installs into an absent ext dir", () => {
  const dir = tmp();
  const mcpb = makeMcpb(dir, { "manifest.json": '{"name":"x"}', "server.js": "// x" });
  const extDir = join(dir, "Claude Extensions", "local.mcpb.test.bridge");
  const r = sh(`_desktop_bridge_install_bundle "${mcpb}" "${extDir}"; echo "RC:$?"`);
  assert.match(r.stdout, /RC:0/, r.stderr);
  assert.ok(existsSync(join(extDir, "manifest.json")));
  assert.ok(existsSync(join(extDir, "server.js")));
  assert.equal(readFileSync(join(extDir, "manifest.json"), "utf8"), '{"name":"x"}');
});

test("_desktop_bridge_install_bundle: identical re-install is idempotent (rc 0)", () => {
  const dir = tmp();
  const mcpb = makeMcpb(dir, { "manifest.json": '{"name":"x"}', "server.js": "// x" });
  const extDir = join(dir, "Claude Extensions", "local.mcpb.test.bridge");
  let r = sh(`_desktop_bridge_install_bundle "${mcpb}" "${extDir}"; echo "RC:$?"`);
  assert.match(r.stdout, /RC:0/, r.stderr);
  r = sh(`_desktop_bridge_install_bundle "${mcpb}" "${extDir}"; echo "RC:$?"`);
  assert.match(r.stdout, /RC:0/, "idempotent on identical content");
});

test("_desktop_bridge_install_bundle: refuses on different installed content + manual fallback hint", () => {
  const dir = tmp();
  const mcpb = makeMcpb(dir, { "manifest.json": '{"name":"x","version":"2"}', "server.js": "// new" });
  const extDir = join(dir, "Claude Extensions", "local.mcpb.test.bridge");
  mkdirSync(extDir, { recursive: true });
  writeFileSync(join(extDir, "manifest.json"), '{"name":"x","version":"1"}'); // different
  const r = sh(`_desktop_bridge_install_bundle "${mcpb}" "${extDir}"; echo "RC:$?"`);
  assert.match(r.stdout, /RC:4/);
  assert.match(r.stderr, /DIFFERENT/);
  assert.match(r.stderr, /Settings > Extensions/);
  // The installed (different) content must NOT be clobbered.
  assert.equal(readFileSync(join(extDir, "manifest.json"), "utf8"), '{"name":"x","version":"1"}');
});

test("desktop_install_bridge: end-to-end installs the bundle and writes isEnabled:true", () => {
  const dir = tmp();
  const mcpb = makeMcpb(dir, { "manifest.json": '{"name":"recording-rig-bridge"}', "server.js": "// bridge" });
  const extDir = join(dir, "Claude Extensions", "local.mcpb.hellblazer.recording-rig-bridge");
  const settings = join(dir, "Claude Extensions Settings", "local.mcpb.hellblazer.recording-rig-bridge.json");
  const r = sh(`desktop_install_bridge; echo "RC:$?"`, {
    RIG_BRIDGE_MCPB: mcpb,
    RIG_BRIDGE_EXT_DIR: extDir,
    RIG_BRIDGE_SETTINGS: settings,
  });
  assert.match(r.stdout, /RC:0/, r.stderr);
  assert.ok(existsSync(join(extDir, "server.js")), "bundle unpacked");
  assert.equal(readJSON(settings).isEnabled, true, "enable flag written");
  assert.match(r.stdout, /installed and enabled/);
});

// --- rr-7u0: --install-profile + --seed-from-primary ---

// A fake `pgrep` on PATH so the A9 guard is exercised deterministically:
// exitCode 0 == "a Claude.app is running", 1 == "none running".
function pgrepDir(dir, exitCode) {
  const bin = join(dir, "fakebin");
  mkdirSync(bin, { recursive: true });
  const p = join(bin, "pgrep");
  writeFileSync(p, `#!/usr/bin/env bash\nexit ${exitCode}\n`);
  chmodSync(p, 0o755);
  return bin;
}
const withPgrep = (bin, env = {}) => ({ ...env, PATH: `${bin}:${process.env.PATH}` });

test("desktop_install_profile: refuses (A9) when a Claude.app is running — no dir created", () => {
  const dir = tmp();
  const rig = join(dir, "Claude-Rig"); // must not exist yet
  const r = sh(`desktop_install_profile; echo "RC:$?"`, withPgrep(pgrepDir(dir, 0), { CLAUDE_RIG_DIR: rig }));
  assert.match(r.stdout, /RC:6/);
  assert.match(r.stderr, /running/);
  assert.ok(!existsSync(rig), "profile dir must not be created when refusing");
});

test("desktop_install_profile: creates the profile dir when no Claude.app is running", () => {
  const dir = tmp();
  const rig = join(dir, "Claude-Rig");
  // spawnSync stdin is not a tty -> the live launch+login wait is skipped.
  const r = sh(`desktop_install_profile; echo "RC:$?"`, withPgrep(pgrepDir(dir, 1), { CLAUDE_RIG_DIR: rig }));
  assert.match(r.stdout, /RC:0/, r.stderr);
  assert.ok(existsSync(rig), "profile dir created");
  assert.match(r.stdout, /non-interactive/, "interactive login wait skipped under spawnSync");
});

test("desktop_seed_from_primary: refuses (A9) when a Claude.app is running — no copy", () => {
  const dir = tmp();
  const primary = join(dir, "Claude");
  mkdirSync(primary, { recursive: true });
  writeFileSync(join(primary, "Cookies"), "SESSION");
  const rig = join(dir, "Claude-Rig");
  mkdirSync(rig, { recursive: true });
  const r = sh(`desktop_seed_from_primary; echo "RC:$?"`, withPgrep(pgrepDir(dir, 0), {
    CLAUDE_RIG_DIR: rig,
    RIG_PRIMARY_PROFILE: primary,
    RIG_SEED_AUTH_PATHS: "Cookies",
  }));
  assert.match(r.stdout, /RC:6/);
  assert.ok(!existsSync(join(rig, "Cookies")), "nothing copied while a Claude.app is running");
});

test("desktop_seed_from_primary: no-clobber when Rig already has auth state", () => {
  const dir = tmp();
  const primary = join(dir, "Claude");
  mkdirSync(primary, { recursive: true });
  writeFileSync(join(primary, "Cookies"), "PRIMARY-SESSION");
  const rig = join(dir, "Claude-Rig");
  mkdirSync(rig, { recursive: true });
  writeFileSync(join(rig, "Cookies"), "RIG-SESSION"); // pre-existing
  const r = sh(`desktop_seed_from_primary; echo "RC:$?"`, withPgrep(pgrepDir(dir, 1), {
    CLAUDE_RIG_DIR: rig,
    RIG_PRIMARY_PROFILE: primary,
    RIG_SEED_AUTH_PATHS: "Cookies",
  }));
  assert.match(r.stdout, /RC:8/);
  assert.match(r.stderr, /refusing to clobber|already has auth/i);
  assert.equal(readFileSync(join(rig, "Cookies"), "utf8"), "RIG-SESSION", "existing Rig session untouched");
});

test("desktop_seed_from_primary: happy path copies present artifacts, preserving mtime", () => {
  const dir = tmp();
  const primary = join(dir, "Claude");
  mkdirSync(join(primary, "Local Storage"), { recursive: true });
  writeFileSync(join(primary, "Cookies"), "SESSION");
  writeFileSync(join(primary, "Local Storage", "leveldb.txt"), "LS");
  const past = new Date(Date.now() - 7 * 86400 * 1000);
  utimesSync(join(primary, "Cookies"), past, past);
  const rig = join(dir, "Claude-Rig");
  const r = sh(`desktop_seed_from_primary; echo "RC:$?"`, withPgrep(pgrepDir(dir, 1), {
    CLAUDE_RIG_DIR: rig,
    RIG_PRIMARY_PROFILE: primary,
    RIG_SEED_AUTH_PATHS: "Cookies\nLocal Storage\nIndexedDB", // IndexedDB absent -> skipped
  }));
  assert.match(r.stdout, /RC:0/, r.stderr);
  assert.equal(readFileSync(join(rig, "Cookies"), "utf8"), "SESSION");
  assert.equal(readFileSync(join(rig, "Local Storage", "leveldb.txt"), "utf8"), "LS");
  // cp -p preserves mtime (compare to the nearest second).
  const srcM = Math.floor(past.getTime() / 1000);
  const dstM = Math.floor(statSync(join(rig, "Cookies")).mtimeMs / 1000);
  assert.ok(Math.abs(srcM - dstM) <= 1, `mtime preserved (src ${srcM}, dst ${dstM})`);
});
