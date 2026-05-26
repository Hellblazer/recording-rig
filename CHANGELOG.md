# Changelog

All notable changes to recording-rig are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
