# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

recording-rig is both a standalone framework and a Claude Code plugin for recording deterministic Claude Code sessions (tutorials, demos, screencasts, regression fixtures). The load-bearing design choice is **hook-driven coordination**: the driver watches `/tmp/${SESSION}.*` sentinel files written by Claude Code lifecycle hooks (`UserPromptSubmit`, `Stop`, `PostToolUse`, `PreToolUse`, `SessionStart`) rather than scraping the TUI for state. `docs/design.md` is required reading before changing anything in `bin/` or `lib/`; the "Core insight" section explains why TUI scraping is structurally broken (spinner-glyph drift, runtime-reconfigurable participle dictionary, mid-redraw text).

## Common commands

```bash
bin/doctor.sh                    # verify prereqs (tmux, jq, asciinema, agg, claude, node 20+)
bin/record.sh path/spec.json     # run a recording; writes /tmp/<session>.cast + .gif (on validate-pass)
bin/validate.mjs <cast-path>     # standalone validator pass on an existing cast
```

Plugin-mode equivalents (when installed via marketplace):

```
/recording-rig:doctor
/recording-rig:author [out.json]
/recording-rig:record path/spec.json
/recording-rig:diagnose <session>
```

Env knobs: `SKIP_VALIDATE=1` (override validator refusal for known-good cases), `SKIP_CONSENT_SWEEP=1` (skip the auxiliary tmux session that dismisses claude's first-run consent dialogs), `AGG_IDLE_TIME_LIMIT`, `GATE_PRE_ENTER_SEC` (default 5), `GATE_POST_ENTER_SEC` (default 2).

There is no project test suite yet. CI runs `.github/workflows/version-parity.yml` on tag push (and on PRs touching `.claude-plugin/plugin.json` or `.claude-plugin/marketplace.json`) to enforce manifest/tag parity.

## Architecture

`bin/record.sh` is the orchestrator: it preflights the spec, renders hooks via `bin/render-hooks.sh` into a `--settings` file that claude consumes, spawns a tmux session via `bin/tmux-session.sh` (optionally with a companion-observer pane), starts `asciinema rec` against the tmux session, runs `bin/driver.sh` to paste commands and navigate `AskUserQuestion` gates, then validates the cast via `bin/validate.mjs` before `agg` renders the GIF. The driver and the agent never share text — they share sentinel files under `/tmp/${SESSION}.*` written by hooks. Validation refuses to render the GIF on missing positive signals or forbidden markers, so a session that aborted silently never publishes.

A tutorial is one JSON spec. Required: `agent.command` or `agent.commands[0]`. README.md §"Spec format" documents every field; key ones are `gates[]` (ordered AskUserQuestion answers, per-command via `for_command`), `hooks.capture_tools[]` (named PostToolUse sentinels), `companion` (optional second pane that *subscribes* to sentinels — never drives state), `validate`, and `pacing`. **Desktop-backend fields** (README §"Desktop backend"): `backend: "desktop"`, top-level `surface` (NOT under `desktop` — matches `SpecReader.swift`), `system_prompt_prologue` (prepended to the first composer paste — Claude.app has no system-prompt flag; plain-request framing, never "you are being recorded"), and `desktop.checkpoints[]` of `{name, required}` (required ones asserted in-order against the bridge transcript). For desktop, `validate.*` runs against the transcript JSONL, not a cast.

## Gotchas with project-specific cost-of-learning

These are load-bearing knowledge that took real time to discover. Full context in `docs/design.md`:

- **`PostToolUse` matcher semantics flip on content sniff** — `Bash|Edit` is treated as exact-string OR-list; anything with `()`, `.`, or anchors is JS regex. Behavior is observed, not documented; re-verify on Claude Code upgrade.
- **Always anchor `PostToolUse` regex with `^...$`** — otherwise the final `*_result` tool overwrites your sentinel with empty.
- **`tool_response` shape varies by MCP transport** — HTTP delivers an array of content blocks (camelCase); stdio delivers a JSON-encoded string (snake_case). Use `if type=="array" then .[0].text else . end | fromjson`. Always `tr -d '\n'` before writing.
- **`claude -p` (non-interactive) silently breaks any flow using `AskUserQuestion`** — gates have no UI under `-p`; claude returns a default that skills interpret as "decline". Use interactive `claude` inside tmux.
- **`tmux send-keys -l` drops characters on long inputs** — use `tmux load-buffer` + `tmux paste-buffer` for slash commands.
- **`validate.mjs` is not a terminal emulator** — concatenates `o` events and strips ANSI; cursor-overwritten content leaves ghost text. For strict assertions, ask the agent to emit fresh-line sentinels like `ANSWER=42`.
- **Companion panes must not call `start_*` tools** — they share backend state with the agent pane via sentinels and observe only. Driving from both panes hits state-machine 409s and worker-queue serialization races.

## Releases

Hand-cut, tag-triggered, ref-pinned. Full procedure in `docs/RELEASE.md`. Standing rules (apply on every release):

1. **Releases are hand-cut.** Tag push triggers parity validation; merges to main do not publish.
2. **`.claude-plugin/plugin.json` `version` is canonical** for this repo. Every release bumps it in lockstep with the tag — **and** with the self-hosted `.claude-plugin/marketplace.json` (the `recording-rig` plugin entry's `version` and `source.ref`). All three move together.
3. **Tags are annotated, not lightweight**: `git tag -a v<X.Y.Z> -m "<summary>"`.
4. **recording-rig self-hosts its marketplace** (`.claude-plugin/marketplace.json`, like nexus). The plugin entry's `source` is the whole-repo `"git"` form pinned to an immutable release tag (`ref: "v<X.Y.Z>"`); `git-subdir` is for monorepos, not this single-plugin repo. Optional `sha` pin for belt-and-suspenders.
5. **One channel.** No `-rc`, `-canary`, `-dev` variants until proven necessary.
6. **Releaser is human.** AI prepares PRs; human merges and tags.
7. **Parity stays strict.** `.github/workflows/version-parity.yml` fails any tag whose `plugin.json` version, `marketplace.json` entry version, or `marketplace.json` `source.ref` disagree with it, and any PR that breaks either manifest's well-formedness or the marketplace↔plugin.json version match.
8. **`CHANGELOG.md` entry lands with the version bump PR**, not after the tag.

## Reference

- `docs/design.md` — full design rationale, sentinel contract, hook-matcher semantics, ruled-out approaches.
- `CONTRIBUTING.md` — dev setup, test discipline, PR rules, and the release protocol (summary + standing rules).
- `docs/RELEASE.md` — detailed release procedure, self-hosted `marketplace.json` + `source` shape, scope of the parity check, install instructions.
- `.claude/skills/release/` — repo-maintainer skill that preps a release (branch + lockstep bump + CHANGELOG + deterministic gate + PR), then stops for the human. Not shipped with the plugin.
- `CHANGELOG.md` — version history.
- `examples/single-pane.json`, `examples/two-pane.json`, `examples/gated.json` — minimal spec templates.
- `test-runs/tutorial-*.json` — specs that produce the README GIFs (canonical examples of the spec format).


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
