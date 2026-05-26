---
name: doctor
description: Verify that recording-rig prereqs are installed and working, or run an opt-in macOS desktop setup subcommand. Use when the user asks "is recording-rig set up", "check my rig install", "/recording-rig:doctor", before a first-time recording, or to install/probe the desktop backend (bridge, profile, surfaces). Wraps bin/doctor.sh — CLI binary/version/login checks plus the macOS desktop advisories and the --install-*/--probe-surfaces/--verify-bridge subcommands.
---

# doctor

Verify the host can run a recording end-to-end before the user tries — and, on macOS,
set up / probe the desktop backend.

## How it runs

`"${CLAUDE_PLUGIN_ROOT}/bin/doctor.sh"` is the single source of truth — run it and
report its output; do not re-implement the checks inline. Forward any argument verbatim:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/doctor.sh" $ARGUMENTS
```

- **No argument** → all prereq checks (below). Exit 0 = all hard checks passed.
- **A desktop subcommand** → that opt-in action instead of the checks (macOS only).

## Checks (no-argument run)

1. **Binaries on PATH** — `tmux`, `jq`, `asciinema`, `agg`, `claude`, `node` (hard fail if missing). Suggested installs (macOS): `brew install tmux jq asciinema agg node`; `claude` per Anthropic's instructions.
2. **bash 4+** — record.sh refuses bash 3.2 (macOS default); `brew install bash`.
3. **asciinema output format** — the rig forces asciicast-v2 (v3 defaults to v3).
4. **claude logged in** — `claude --version` succeeds, else route to `claude login`.
5. **tmux can spawn a detached session** — isolates tmux-config breakage.
6. **agg can render a trivial cast.**
7. **macOS desktop advisories** (Darwin only; WARN, never fail — a CLI user needs none of them): ffmpeg/gifski/swiftc, Claude.app present, Accessibility + Screen Recording permission (via `bin/perms-check`), the Claude-Rig profile, the bridge installed **and** enabled, the AX-selector + surface probe-cache freshness, and the soft-miss trend.

## Desktop subcommands (macOS, opt-in)

Forwarded to `bin/doctor.sh` by argument. These are mutating / live actions; each says up
front what it changes and refuses on collision. Reach them as `/recording-rig:doctor <flag>`.

- `--install-bridge` — install + enable the recording-rig-bridge in the Claude-Rig profile.
- `--install-profile` — create the isolated profile and wait for an interactive login.
- `--seed-from-primary` — copy the primary profile's web-session auth into Claude-Rig.
- `--probe-surfaces` — validate the live surfaces against a running Claude-Rig and refresh the probe caches (prerequisite for authoring a desktop spec).
- `--verify-bridge` — call a bridge tool and assert the response transport shape (catches drift).

## Reporting

- All checks pass → report "doctor: all checks passed" with one summary line.
- Any hard check fails → list each failure with its exact install command; don't proceed to recording.
- Desktop advisories are WARN — surface them, but they never block a CLI recording.

## What this skill does NOT do

- Install host packages (the package manager is the user's responsibility).
- Modify `~/.claude/` state on a no-argument run. (The desktop subcommands DO mutate the Claude-Rig profile — that is their explicit purpose, and they refuse on collision.)
- Run an actual recording (route to the `record` skill).
