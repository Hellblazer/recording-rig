# Release procedure

recording-rig is published as a Claude Code plugin **through its own marketplace**:
`.claude-plugin/marketplace.json` in this repo registers the `recording-rig` plugin
and pins its `source.ref` to an immutable release tag. Installs and updates resolve
through that entry. Because the entry pins to a tag rather than tracking the branch,
pushes to `main` between releases do **not** change what installed users see — only
cutting a new tag (and bumping the manifests to match) does.

This mirrors the pinned-source model used by `Hellblazer/nexus` (which self-hosts its
own `marketplace.json` for `conexus`/`sn`). recording-rig is its own single-plugin repo
— the plugin lives at the repo root — so its `source` uses the whole-repo `"git"` form,
not `"git-subdir"`.

## Install (users)

```text
/plugin marketplace add Hellblazer/recording-rig
/plugin install recording-rig@recording-rig
```

The marketplace and the plugin share the name `recording-rig` (single-plugin repo).
Installed versions follow the pinned tag; run `/plugin marketplace update recording-rig`
after a new release to pick it up.

## Bump and tag (releasing `v<X.Y.Z>`)

All three of these move in **lockstep** — the `version-parity` workflow fails a tag whose
manifests disagree with it:

1. Branch off `main`: `git checkout -b release/v<X.Y.Z>`.
2. Bump **`.claude-plugin/plugin.json`** `version` → `<X.Y.Z>` (the canonical version for this repo).
3. Bump **`.claude-plugin/marketplace.json`** — the `recording-rig` plugin entry's
   `version` → `<X.Y.Z>` **and** its `source.ref` → `v<X.Y.Z>`, together.
4. Add a `## [<X.Y.Z>] — YYYY-MM-DD` entry to `CHANGELOG.md` covering user-visible changes since the last release.
5. Commit, push, open a PR:
   ```bash
   git commit -am "release: v<X.Y.Z>"
   git push -u origin release/v<X.Y.Z>
   gh pr create --title "release: v<X.Y.Z>"
   ```
6. Merge the PR. On main:
   ```bash
   git checkout main && git pull
   git tag -a v<X.Y.Z> -m "release: v<X.Y.Z>"
   git push origin v<X.Y.Z>
   ```
7. Watch the workflow: `gh run watch $(gh run list --workflow=version-parity.yml --limit=1 --json databaseId -q '.[0].databaseId')`.

Tags are **annotated** (`git tag -a -m`), not lightweight — they carry author, date, and a
release message that show up in `git log` and on the GitHub release page. Lightweight tags
(bare `git tag v<X.Y.Z>`) skip all of that and can't be signed.

Bad tags can be re-cut after fixing the manifests
(`git tag -d v<X.Y.Z> && git push origin :v<X.Y.Z>`, then start over from step 1 on a new
release branch).

## The `source` object

```jsonc
"source": {
  "source": "git",
  "url": "https://github.com/Hellblazer/recording-rig.git",
  "ref": "v<X.Y.Z>"
}
```

- Use the object form, not a relative path like `"./recording-rig"`.
- Use `"git"` (whole repo). `"git-subdir"` is for plugins that live as a subdirectory of a
  monorepo (e.g. nexus's `conexus`/`sn`); recording-rig is its own repo.
- `ref` only ever points at an immutable release tag — never a branch, never a rolling tag.
- Tags are mutable. For belt-and-suspenders immutability, also pin the commit `sha`:
  ```jsonc
  "source": {
    "source": "git",
    "url": "https://github.com/Hellblazer/recording-rig.git",
    "ref": "v<X.Y.Z>",
    "sha": "<40-char commit sha>"
  }
  ```

## What the parity workflow enforces

`.github/workflows/version-parity.yml` runs on every PR touching either manifest (or the
workflow), on push to `main`, and on `v*` tag push:

- **Always** — `plugin.json` is well-formed JSON with a semver `version`; `marketplace.json`
  is well-formed, carries the `recording-rig` plugin entry with a semver `version` and a
  `git` `source` whose `ref` is a `v`-tag, and the entry `version` **equals** `plugin.json`'s.
- **On a `v*` tag push** — additionally, `plugin.json` `version`, the marketplace entry
  `version`, and the marketplace `source.ref` all match the tag (`source.ref == tag`,
  the versions == tag minus the `v`). A tag whose manifests still point at the previous
  release fails here — that is the gate forcing step 3 before the tag.
