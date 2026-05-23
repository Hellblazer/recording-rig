# Changelog

All notable changes to recording-rig are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `CLAUDE.md` with project-specific guidance for Claude Code sessions — covers the hook-driven coordination model, common commands, load-bearing gotchas, and the standing release rules.
- `CHANGELOG.md` (this file).

### Changed
- `version-parity` workflow now also runs on pull requests (touching `plugin.json`) and pushes to `main`, asserting the manifest is well-formed JSON with a semver-shaped `version`. The strict tag-vs-version match still runs only on `v*` tag pushes.
- `docs/RELEASE.md` updated to use **annotated** tags (`git tag -a -m`) and to include the `CHANGELOG.md` step in the release procedure.

## [0.1.2] — 2026-05-23

### Added
- `.github/workflows/version-parity.yml` — on `v*` tag push, fails the run if `.claude-plugin/plugin.json` `version` does not match the tag (minus the `v` prefix). Catches manifest/tag drift at release time.
- `docs/RELEASE.md` — release procedure plus the consuming-marketplace `source` shape for ref-pinning so installed users only update on new tags, not on every push to `main`.

## [0.1.1]

### Fixed
- tmux socket cleanup on rig exit.

## [0.1.0]

Initial release.
