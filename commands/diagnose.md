---
description: Diagnose a failed recording-rig run (CLI or desktop) — examines the cast or bridge transcript/.mov/bridge-log, sentinels, rendered hooks, and spec to identify the failure mode and propose a fix.
argument-hint: <session-name-or-cast-path> [spec.json]
allowed-tools: [Bash, Read]
---

Invoke the `diagnose` skill on `$ARGUMENTS`.

The skill first detects the backend, then walks the matching taxonomy.

**CLI backend:**
- Validator `FAILED`: missing required / forbidden present
- Hung before `session-start` (consent dialogs)
- Hung after `session-start` but no `prompt-submitted` (attach race / trust dialog)
- Hung after paste but no `turn-end` (slow model / unanswered AskUserQuestion)
- Companion never ran (envfile malformed / hook didn't fire)
- `must_contain_in_order` order mismatch (cursor overwrite reordering)

**Desktop backend** (runs `bin/diagnose-desktop.sh ${SESSION} [spec]`):
- Checkpoint coverage: missing required checkpoint / synthesized (soft-miss) vs genuine turn_end
- Soft-miss trend (instruction drift) over the last N desktop runs
- Capture coverage: `.mov` duration vs the transcript's tool-call span
- Bridge-log liveness: bridge never connected in Claude-Rig, or went quiet mid-session

Reports symptom + root cause + specific fix + how to verify. Read-only — does not apply fixes.
