# Changelog

All notable changes to recording-rig are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] — 2026-09-08

**Desktop backend follows Claude.app 1.46388.** Patch release; the CLI backend is unchanged.

### Fixed
- **Desktop selectors drift on Claude.app 1.46388** (rr-ay1) — the sidebar Chat/Code/Cowork
  `AXButton`s became two radio groups (a top-left mode radio `Chat and Cowork` | `Code`, and the
  composer's `Surface` group `Chat` | `Cowork` carrying only an `AXTitle`), so every desktop run
  died at `armWait timed out ... AXButton:Chat`. `bin/desktop-ax-selectors.json` now gives each
  surface an ordered `nav[]` press sequence and a selector may match on `title` as well as
  `description`; the legacy single `navButton` key still decodes. `ax-dump` lists
  `AXRadioButton` by default so the next drift is visible without `RIG_AXDUMP_ROLES`.

### Added
- `test-runs/tutorial-desktop-chat.json` — a Chat-surface tutorial spec (three ordered
  checkpoints, `TUTORIAL_COMPLETE` terminator) recorded against Claude.app 1.46388.

## [0.3.0] — 2026-05-27

**Multi-surface desktop choreography.** A single desktop recording can now tour several
Claude.app surfaces in one continuous capture. The CLI backend is unchanged.

### Added
- **Multi-surface `steps[]`** (rr-u07) — a top-level `steps[]` of `{surface, command,
  system_prompt_prologue?}` drives several surfaces (e.g. Code → Chat → CoWork) in ONE
  continuous capture, mixing coordination providers per step (bridge for Chat/Code,
  agent-transcript-tail for CoWork). Supersedes the single-surface fields; existing
  single-surface specs are unchanged. Worked example: `examples/desktop-tiers.json` (the
  README's tier-semantics demo), driven by a driver↔`record.sh` `step-K-submitted` /
  `step-K-done` sentinel handshake.
- **Automatic Stage Manager handling** (rr-sm0) — `record.sh` disables macOS Stage Manager
  before a desktop recording and restores it on exit (including on interrupt), so it can't
  reshuffle the Rig window mid-capture on surface switches. `SKIP_STAGE_MANAGER_TOGGLE=1`
  opts out.
- `ax-dump` now emits each node's position/size and `[focused]` state (selector authoring +
  diagnosis).

### Fixed
- **CoWork (and any later multi-surface step) now lands its prompt** (rr-bw3) — the driver
  drives the focused/on-screen composer instead of a transient one left mid-transition, with
  a post-switch settle. Previously a later step could submit into a stale composer and never
  start its turn.
- Multi-surface `steps[]`-only specs pass the spec-sanity preflight; the gate/checkpoint
  preflight is evaluated per-run (a bridge step can carry the spec's checkpoints) rather than
  rejecting on a fallback step; consecutive bridge steps each wait for their own `rig_turn_end`
  (a shared turn-end sentinel no longer lets a later step complete prematurely) (rr-u07).

### Changed
- README: documents the `steps[]` schema + the multi-surface tier demo, and notes the
  one-time CoWork working-folder selection (like Code).

## [0.2.1] — 2026-05-26

Desktop-backend fixes for **Claude.app v1.9255.0**. The app auto-updated ~700 builds
from the v1.8555.2 the v0.2.0 Desktop backend was certified against, regressing two
things; both are fixed here, no app pinning. The CLI backend is unchanged.

### Fixed
- **Desktop capture geometry** (`rr-79v`) — v1.9255.0 exposes a small secondary
  on-screen window (~280×320) for the same pid; ScreenCaptureKit was grabbing it
  instead of the main window, producing a tiny black capture. Capture now selects the
  **largest** on-screen window owned by the Claude-Rig pid.
- **`examples/two-pane`** (`rr-x15`) — the demo's `JOB_ID` is now runtime-dynamic so the
  recorded model reliably makes the Bash tool call (it was answering from the prompt).

### Added
- **Competing-Claude.app guard** (`rr-re6`) — hands-free Desktop recording requires that
  no *other* Claude.app instance is running. macOS activates per app-bundle, so a second
  instance keeps the foreground when the Claude-Rig instance launches, leaving it
  backgrounded with an unmaterialized accessibility tree (the driver then times out — a
  manual window click was the prior workaround). `record.sh` now refuses while a non-Rig
  Claude.app main is running and `doctor` warns; override with `RIG_ALLOW_COMPETING_CLAUDE=1`.
- **Desktop demo GIFs** in the README — the Chat, Code, and CoWork surfaces, recorded live.

## [0.2.0] — 2026-05-26

The headline of this release is the **Desktop backend** (RDR-001): recording the
real Claude.app, not just a headless CLI session. The CLI backend is unchanged and
remains the default — every Desktop addition is additive and macOS-only.

### Added
- **Desktop backend** (`backend: "desktop"`, macOS) — drive and screen-record the real
  Claude.app over Accessibility + ScreenCaptureKit across three surfaces: **Chat**,
  **Code**, and **CoWork**. Coordination is hook-free: the model calls bridge tools
  (`rig_checkpoint`, `rig_turn_end`) that emit the same sentinels as the CLI hooks
  (Chat/Code, via the bridge), or the rig tails the agent transcript (CoWork). Selected
  with the top-level `surface` field; `coordination` defaults to `auto`.
- **`recording-rig-bridge`** MCP extension (`bridge/`) — the sentinel-emitter bridge the
  Desktop backend's Chat/Code surfaces coordinate through.
- **`bin/desktop-driver`** (Swift) — the AX-drive + ScreenCaptureKit capture executable,
  plus the `bin/ax-dump` selector-discovery helper and `bin/perms-check` TCC reporter
  (built via `bin/build-*.sh`).
- **`doctor` desktop mode** — on macOS, advisory checks for ffmpeg/gifski/swiftc,
  Claude.app, Accessibility + Screen Recording permission, the isolated Claude-Rig
  profile, the bridge installed-and-enabled, and probe-cache freshness (all WARN, never
  failing a CLI user). Plus opt-in setup subcommands reachable as `/recording-rig:doctor`:
  `--install-bridge`, `--install-profile`, `--seed-from-primary`, `--probe-surfaces`,
  `--verify-bridge`.
- **`diagnose` desktop forensics** — checkpoint coverage, soft-miss trend, capture
  coverage, and bridge-log liveness, with a synthesized top-line `primary:` verdict.
- **`author-spec` desktop authoring** — a backend-first flow that walks Desktop specs
  (surface + coordination, a `system_prompt_prologue` starter, checkpoints, Code
  trusted-folder seeding) and hard-gates on a fresh surface probe cache.
- **Self-hosted marketplace** — `.claude-plugin/marketplace.json` registers the plugin
  with a tag-pinned `source`. Install with `/plugin marketplace add Hellblazer/recording-rig`.
- Example specs: `examples/desktop-chat.json`, `examples/desktop-code.json`,
  `examples/desktop-cowork.json`, and `examples/cli-smoke.json` (the CLI byte-identical
  regression probe). `docs/design.md` and `README.md` gained Desktop backend sections.
- `CLAUDE.md` project guidance and this `CHANGELOG.md`.

### Changed
- `version-parity` now also runs on pull requests (touching `.claude-plugin/plugin.json`
  or `.claude-plugin/marketplace.json`) and pushes to `main`, and enforces
  `marketplace.json` ↔ `plugin.json` ↔ tag parity (entry version matches `plugin.json`
  always; entry version **and** `source.ref` match the tag on a `v*` push).
- `docs/RELEASE.md` rewritten for the self-hosted, ref-pinned flow (annotated tags;
  lockstep bump of `plugin.json` + `marketplace.json` + `CHANGELOG.md`).

## [0.1.2] — 2026-05-23

### Added
- `.github/workflows/version-parity.yml` — on `v*` tag push, fails the run if `.claude-plugin/plugin.json` `version` does not match the tag (minus the `v` prefix). Catches manifest/tag drift at release time.
- `docs/RELEASE.md` — release procedure plus the consuming-marketplace `source` shape for ref-pinning so installed users only update on new tags, not on every push to `main`.

## [0.1.1]

### Fixed
- tmux socket cleanup on rig exit.

## [0.1.0]

Initial release.
