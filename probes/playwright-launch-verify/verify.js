// SPDX-License-Identifier: MIT
//
// RDR-001 P0.5 launch verification.
//
// Confirms playwright >= 1.59.0 can _electron.launch() Claude.app v1.8555.2
// (Electron 41.6.1) without the `bad option: --remote-debugging-port=0`
// failure that affects playwright 1.57.0 / 1.58.0 (microsoft/playwright#39008,
// fixed in 1.58.1). Records observed playwright + electron versions, the PID
// of the launched process (to distinguish a clean spawn from attachment to
// an existing instance via the Electron single-instance lock), and whether
// firstWindow() returns a usable page handle.
//
// Uses a per-run --user-data-dir under /tmp so the verification does not
// touch the user's primary Claude.app profile.

import { _electron as electron } from "playwright";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const CLAUDE_BIN = "/Applications/Claude.app/Contents/MacOS/Claude";
const LAUNCH_TIMEOUT_MS = 30_000;
const FIRSTWINDOW_TIMEOUT_MS = 20_000;

const profileDir = mkdtempSync(join(tmpdir(), "claude-rig-p0-5-"));

const result = {
  probe: "P0.5",
  bead: "rr-k9v",
  date: new Date().toISOString(),
  playwright_version: null,
  claude_binary: CLAUDE_BIN,
  profile_dir: profileDir,
  launch: { status: "pending" },
  first_window: { status: "pending" },
  launch_pid: null,
  outcome: "pending",
  error: null,
};

try {
  const playwrightPkg = await import("playwright/package.json", { with: { type: "json" } })
    .then((m) => m.default)
    .catch(() => null);
  if (playwrightPkg) result.playwright_version = playwrightPkg.version;
} catch (e) {
  result.playwright_version = `lookup-failed: ${e.message}`;
}

let electronApp = null;
const launchStart = Date.now();

try {
  electronApp = await electron.launch({
    executablePath: CLAUDE_BIN,
    args: [`--user-data-dir=${profileDir}`],
    timeout: LAUNCH_TIMEOUT_MS,
  });
  result.launch.status = "ok";
  result.launch.ms = Date.now() - launchStart;
  result.launch_pid = electronApp.process()?.pid ?? null;
} catch (e) {
  result.launch.status = "failed";
  result.launch.ms = Date.now() - launchStart;
  result.error = `launch: ${e.message}`;
  result.outcome = e.message.includes("--remote-debugging-port=0")
    ? "FAIL_BAD_OPTION_REMOTE_DEBUG_PORT"
    : "FAIL_LAUNCH";
  console.log(JSON.stringify(result, null, 2));
  try { rmSync(profileDir, { recursive: true, force: true }); } catch {}
  process.exit(2);
}

const fwStart = Date.now();
try {
  const page = await electronApp.firstWindow({ timeout: FIRSTWINDOW_TIMEOUT_MS });
  const url = page.url();
  let title = null;
  try {
    title = await page.title();
  } catch (e) {
    title = `title-error: ${e.message}`;
  }
  result.first_window.status = "ok";
  result.first_window.ms = Date.now() - fwStart;
  result.first_window.url = url;
  result.first_window.title = title;
} catch (e) {
  result.first_window.status = "failed";
  result.first_window.ms = Date.now() - fwStart;
  result.error = `firstWindow: ${e.message}`;
  result.outcome = "FAIL_FIRSTWINDOW";
}

try {
  const windows = electronApp.windows();
  result.windows_at_close = windows.length;
} catch {}

try {
  await electronApp.close();
  result.close = "ok";
} catch (e) {
  result.close = `failed: ${e.message}`;
}

try { rmSync(profileDir, { recursive: true, force: true }); } catch {}

if (result.outcome === "pending") {
  result.outcome =
    result.launch.status === "ok" && result.first_window.status === "ok"
      ? "PASS"
      : "FAIL";
}

console.log(JSON.stringify(result, null, 2));
process.exit(result.outcome === "PASS" ? 0 : 1);
