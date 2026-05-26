---
description: Check recording-rig prereqs (CLI + macOS desktop), or run an opt-in desktop setup subcommand (--install-bridge, --probe-surfaces, etc.).
argument-hint: "[--install-bridge|--install-profile|--seed-from-primary|--probe-surfaces|--verify-bridge]"
allowed-tools: [Bash, Read]
---

Run `"${CLAUDE_PLUGIN_ROOT}/bin/doctor.sh" $ARGUMENTS` and report the result. The
single script is the source of truth; `$ARGUMENTS` is forwarded verbatim so the
desktop subcommands are reachable through this command, not only the raw shell path.

**No arguments** → run all prereq checks:

- Required binaries: `tmux`, `jq`, `asciinema`, `agg`, `claude`, `node`
- Bash 4+ available
- `asciinema` supports `--output-format asciicast-v2`
- `claude` is logged in (`claude --version` succeeds)
- `tmux` can spawn a detached session
- `agg` can render a trivial cast
- **On macOS, also the desktop-backend advisories** (WARN, never fail): ffmpeg/gifski/swiftc,
  Claude.app, Accessibility + Screen Recording permission, the Claude-Rig profile, the
  bridge installed-and-enabled, and the AX-selector + surface probe-cache freshness.

**A desktop subcommand** (macOS only; opt-in, may mutate the Claude-Rig profile) →
dispatches that action instead of the checks:

- `--install-bridge` — install + enable the recording-rig-bridge in the Claude-Rig profile
- `--install-profile` — create the isolated profile and wait for an interactive login
- `--seed-from-primary` — copy the primary profile's web-session auth into Claude-Rig
- `--probe-surfaces` — validate the live surfaces and refresh the probe caches
- `--verify-bridge` — call a bridge tool and assert the response transport shape

Report any failures with the exact install command / fix. The no-argument checks do not
modify any system state; the subcommands say up front what they change and refuse on collision.
