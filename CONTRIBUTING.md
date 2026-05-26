# Contributing to recording-rig

recording-rig is both a standalone framework and a Claude Code plugin for recording
deterministic Claude Code sessions. This guide covers local development, the test
discipline, and the release protocol.

Read [`docs/design.md`](docs/design.md) before changing anything in `bin/` or `lib/` —
the "Core insight" section explains why the coordination is hook-driven (sentinel files)
rather than TUI-scraping.

## Development

Verify prerequisites first:

```bash
bin/doctor.sh        # tmux, jq, asciinema, agg, claude, node; on macOS also the desktop checks
```

The macOS **Desktop backend** depends on Swift binaries that are build artifacts
(gitignored) — rebuild them after a checkout:

```bash
bin/build-desktop-driver.sh
bin/build-ax-dump.sh
bin/build-perms-check.sh
```

## Tests

There is no test-runner wrapper; tests are `node --test` files colocated with the code.
Run the full suite:

```bash
node --test bin/validate.test.mjs bridge/server.test.mjs \
  lib/quality.test.mjs lib/coordination.test.mjs lib/trusted-folders.test.mjs \
  lib/desktop-doctor.test.mjs bin/doctor.test.mjs bin/diagnose-desktop.test.mjs
swift test --package-path desktop-driver   # macOS desktop-driver unit tests
```

Write the test before the implementation. Keep tests deterministic (seeded randomness,
fixed clocks, stubbed externals, port 0 for dynamic allocation). Live-only arms (anything
that launches `claude` or the Claude.app) are thin shells and are exercised by the
recording gate, not by unit tests — never fake them green.

## Pull requests

- **PRs only — never push directly to `main`.** Branch naming: `feature/<id>-<description>`.
- One coherent change per PR. Run the full test suite before opening it.
- Don't stack a PR on a base branch you intend to delete on merge — deleting the base
  branch **closes** (does not retarget) the stacked PRs.

## Releases

recording-rig is published as **its own pinned-source Claude Code marketplace**
(`.claude-plugin/marketplace.json` in this repo, mirroring `Hellblazer/nexus`). The
marketplace entry pins `source.ref` to an immutable release tag, so `main` advances freely
between releases and installed users only move when a new tag is cut.

The detailed step-by-step lives in [`docs/RELEASE.md`](docs/RELEASE.md). To prepare a
release, run the **`release` skill** (repo-maintainer tooling under `.claude/skills/release/`;
not shipped to plugin users) — ask Claude to "cut a release v\<X.Y.Z\>" and it prepares the
branch + PR, then stops for the human.

### Standing rules

1. **Hand-cut, tag-triggered.** Merges to `main` do not publish; the `v*` tag push fires
   `version-parity`. CI never auto-cuts on merge.
2. **Three versions move in lockstep** — `.claude-plugin/plugin.json` `version`, the
   `recording-rig` entry's `version` in `.claude-plugin/marketplace.json`, and that entry's
   `source.ref` (`= v<X.Y.Z>`). `version-parity` fails any tag where they disagree.
3. **Annotated tags only** — `git tag -a v<X.Y.Z> -m "<summary>"` (never lightweight).
4. **`source.ref` pins an immutable release tag** — never a branch, never a rolling tag.
   Optional `sha` pin for belt-and-suspenders.
5. **Releaser is human.** AI prepares the release branch + PR; a human runs the live gate,
   merges, tags, pushes, and publishes the GitHub Release.
6. **One channel.** No `-rc` / `-canary` / `-dev` variants until proven necessary.
7. **`CHANGELOG.md` entry lands with the version-bump PR**, not after the tag.

### Gate before tagging

- **Deterministic** (AI runs during prep): the full `node --test` suite green; `bin/doctor.sh`
  exits 0; the `version-parity` simulation passes for the target tag.
- **Live** (the human's pre-tag verification): the CLI byte-identical regression
  `bin/record.sh examples/cli-smoke.json`, and the `examples/desktop-*.json` specs record.

### Flow

```text
# AI (the release skill) — prepares, then STOPS:
#   branch release/v<X.Y.Z>; lockstep bump (plugin.json + marketplace.json entry version
#   + source.ref); CHANGELOG [<X.Y.Z>] entry; deterministic gate; open the PR.

# Human — cuts:
git checkout main && git pull
git tag -a v<X.Y.Z> -m "release: v<X.Y.Z> — <summary>"
git push origin v<X.Y.Z>                       # fires version-parity strict tag-match
gh release create v<X.Y.Z> --title "v<X.Y.Z> — <summary>" --notes-file <CHANGELOG [X.Y.Z] section>
```

### Install (users)

```text
/plugin marketplace add Hellblazer/recording-rig
/plugin install recording-rig@recording-rig
# after a new release:
/plugin marketplace update recording-rig
```
