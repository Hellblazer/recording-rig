# Release procedure

recording-rig is published as a Claude Code plugin. Installs and updates resolve
through whichever marketplace registers it (e.g. `Hellblazer/nexus`'s
`marketplace.json`). To decouple installed versions from `main` HEAD, the
marketplace entry pins to a tag rather than tracking the branch — pushes to
`main` between releases do not change what installed users see.

## Bump and tag (this repo)

1. Branch off `main`: `git checkout -b release/v0.1.2`.
2. Bump `.claude-plugin/plugin.json` `version` to the next semver — e.g. `0.1.2`.
3. Add a `## [0.1.2] — YYYY-MM-DD` entry to `CHANGELOG.md` covering user-visible changes since the last release.
4. Commit, push, open a PR:
   ```bash
   git commit -am "release: v0.1.2"
   git push -u origin release/v0.1.2
   gh pr create --title "release: v0.1.2"
   ```
5. Merge the PR. On main:
   ```bash
   git checkout main && git pull
   git tag -a v0.1.2 -m "release: v0.1.2"
   git push origin v0.1.2
   ```
6. Watch the workflow: `gh run watch $(gh run list --workflow=version-parity.yml --limit=1 --json databaseId -q '.[0].databaseId')`.

Tags are **annotated** (`git tag -a -m`), not lightweight — they carry author,
date, and a release message that show up in `git log` and on the GitHub release
page. Lightweight tags (bare `git tag v0.1.2`) skip all of that and can't be
signed.

The `version-parity` workflow runs:
- On every PR touching `.claude-plugin/plugin.json` → asserts the manifest is well-formed JSON with a semver-shaped `version`.
- On push to `main` → same well-formedness check.
- On `v*` tag push → additionally asserts `plugin.json` `version` matches the tag (minus the `v` prefix).

Bad tags can be re-cut after fixing `plugin.json` (`git tag -d v0.1.2 && git push origin :v0.1.2`, then start over from step 1 on a new release branch).

## Update the marketplace entry (consuming repo)

In the consuming marketplace's `marketplace.json`, set the recording-rig entry's
`version` and `source.ref` together:

```jsonc
{
  "name": "recording-rig",
  "version": "0.1.2",
  "source": {
    "source": "git",
    "url": "https://github.com/Hellblazer/recording-rig.git",
    "ref": "v0.1.2"
  }
}
```

Notes on the `source` object:

- Use the object form, not a relative path like `"./recording-rig"`.
- Use `"git"` (whole repo). `"git-subdir"` is for plugins that live as a
  subdirectory of a monorepo; recording-rig is its own repo.
- Tags are mutable. For belt-and-suspenders immutability, also pin the commit:
  ```jsonc
  "source": {
    "source": "git",
    "url": "https://github.com/Hellblazer/recording-rig.git",
    "ref": "v0.1.2",
    "sha": "<40-char commit sha>"
  }
  ```

## Scope of the in-repo parity check

`.github/workflows/version-parity.yml` only verifies `plugin.json` `version`
against the git tag at push time. It cannot verify the marketplace entry on the
consuming side — that parity (marketplace `version` ↔ `source.ref` ↔ this
repo's tag) belongs to the marketplace repo's own CI.
