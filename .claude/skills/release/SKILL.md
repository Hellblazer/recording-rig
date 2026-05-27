---
name: release
description: Prepare a recording-rig release — branch, bump the three versions in lockstep, write the CHANGELOG entry, run the deterministic gate, and open the PR. Use when asked to "cut a release", "prep a release", "release vX.Y.Z", "bump the version", or "do the v0.x.y release". Repo-maintainer tooling (NOT shipped to plugin users). The HUMAN merges, tags, pushes, and publishes — this skill stops at the PR.
---

# release (recording-rig maintainer skill)

Prepare a tag-pinned release of recording-rig. This skill does the AI-side **prep**; a
human does the cut. recording-rig self-hosts a pinned-source marketplace, so a release
moves three versions in lockstep and is gated by `version-parity` at tag time.

Detailed procedure: `docs/RELEASE.md`. Standing rules: `CONTRIBUTING.md` § Releases and
`CLAUDE.md` § Releases.

## HARD RULE — releaser is human

**Stop after opening the PR.** Do NOT merge the PR, create or push a tag, or publish a
GitHub Release unless the human explicitly says to (e.g. "merge", "tag and push", "cut it").
CI never auto-cuts on merge; the tag push is the human's deliberate act.

## Input

The target version `<X.Y.Z>` (semver). Minor bump for new user-visible features, patch for
fixes. If the user didn't give one, infer from the `CHANGELOG.md` `[Unreleased]` content and
confirm before proceeding.

## Prep steps (do these)

1. **Clean base.** Confirm `main` is clean and up to date, then branch:
   `git checkout main && git pull --ff-only && git checkout -b release/v<X.Y.Z>`.
2. **Lockstep bump — all three, or `version-parity` fails the tag:**
   ```bash
   # plugin.json (canonical version)
   tmp=$(mktemp); jq '.version = "<X.Y.Z>"' .claude-plugin/plugin.json > "$tmp" && mv "$tmp" .claude-plugin/plugin.json
   # marketplace.json: the recording-rig entry's version AND source.ref
   tmp=$(mktemp); jq '(.plugins[]|select(.name=="recording-rig")|.version) = "<X.Y.Z>"
     | (.plugins[]|select(.name=="recording-rig")|.source.ref) = "v<X.Y.Z>"' \
     .claude-plugin/marketplace.json > "$tmp" && mv "$tmp" .claude-plugin/marketplace.json
   ```
3. **CHANGELOG.** Roll the `[Unreleased]` items into a new `## [<X.Y.Z>] — <YYYY-MM-DD>`
   (today's date) section with `Added` / `Changed` / `Fixed` groups covering user-visible
   changes since the last tag; leave an empty `## [Unreleased]` at the top.
4. **Deterministic gate — must pass before the PR:**
   ```bash
   bin/build-desktop-driver.sh && bash bin/build-ax-dump.sh && bash bin/build-perms-check.sh   # macOS
   node --test bin/validate.test.mjs bridge/server.test.mjs \
     lib/quality.test.mjs lib/coordination.test.mjs lib/trusted-folders.test.mjs \
     lib/competing-claude.test.mjs lib/desktop-doctor.test.mjs bin/doctor.test.mjs \
     bin/diagnose-desktop.test.mjs   # expect 0 failures
   bash bin/doctor.sh    # expect rc 0
   ```
   Then a parity simulation against the bumped manifests — `plugin.json` version, the
   marketplace entry version, and `source.ref` (minus the `v`) must all equal `<X.Y.Z>`:
   ```bash
   jq -r '.version' .claude-plugin/plugin.json
   jq -r '.plugins[]|select(.name=="recording-rig")|"\(.version) \(.source.ref)"' .claude-plugin/marketplace.json
   ```
5. **Commit + push + PR:**
   ```bash
   git commit -am "release: v<X.Y.Z>"
   git push -u origin release/v<X.Y.Z>
   gh pr create --base main --title "release: v<X.Y.Z>"
   ```
6. **Report** the deterministic gate result and the human's remaining steps (below). **Stop.**

## Human steps (do NOT run these unless told)

1. **Live gate** (launches `claude` / the Claude.app — the human's pre-tag verification):
   `bin/record.sh examples/cli-smoke.json` (CLI byte-identical regression) and the
   `examples/desktop-*.json` specs record. If asked to run the CLI smoke, it is safe (CLI
   backend, deterministic); do NOT run the `desktop-*` specs autonomously (they launch the app).
2. **Merge** the PR.
3. **Tag + push** (fires `version-parity`'s strict tag-match over both manifests):
   ```bash
   git checkout main && git pull
   git tag -a v<X.Y.Z> -m "release: v<X.Y.Z> — <summary>"
   git push origin v<X.Y.Z>
   ```
4. **Publish** the GitHub Release from the CHANGELOG section:
   ```bash
   awk '/^## \[<X.Y.Z>\]/{f=1} f&&/^## \[/&&!/\[<X.Y.Z>\]/{exit} f' CHANGELOG.md > /tmp/notes.md
   gh release create v<X.Y.Z> --title "v<X.Y.Z> — <summary>" --notes-file /tmp/notes.md --verify-tag
   ```

## Invariants (do not relitigate)

- **Three versions in lockstep** — `version-parity` enforces it on the tag push.
- **Annotated tags only** (`git tag -a -m`).
- **`source.ref` = an immutable `v`-tag** — never a branch or rolling tag.
- **Whole-repo `"git"` source** (single-plugin repo) — not `"git-subdir"`.
- **CHANGELOG entry lands in the bump PR**, not after the tag.
- This skill lives in `.claude/skills/` and is **not** part of the shipped plugin.
