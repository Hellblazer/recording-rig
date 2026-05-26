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
import { mkdtempSync, writeFileSync, chmodSync, utimesSync, existsSync } from "node:fs";
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
