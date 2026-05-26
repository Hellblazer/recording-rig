---
description: Interactively author a recording-rig spec JSON — asks the backend (CLI or macOS Desktop) first, then walks through agent command, surface, gates/checkpoints, companion pane, validation, and writes a valid spec file.
argument-hint: [output-path]
allowed-tools: [Read, Write, AskUserQuestion, Bash]
---

Invoke the `author-spec` skill. If `$ARGUMENTS` is set, use it as the output spec path;
otherwise let the skill suggest one based on the user's description.

The skill asks the **backend first** (CLI is the default; Desktop is macOS-only and drives
the real Claude.app), then branches:

- **CLI** — session name + recording shape (single-pane, gated, multi-command, two-pane),
  agent command(s)/cwd/model/bypass-permissions, gates (option indices + hold timings),
  PostToolUse capture + companion env (two-pane), and validation assertions (checked to be
  agent-output, not prompt-echo).
- **Desktop** — a hard gate on a fresh surface probe cache first, then surface
  (chat/code/cowork) and its coordination provider, the agent command, a
  `system_prompt_prologue` starter (chat/code must load the bridge tools first),
  `desktop.checkpoints[]`, gates (chat/code only — refused on cowork), Code trusted-folder
  seeding, and transcript-based validation.

Writes a complete, valid spec the user can immediately run with `/recording-rig:record`.
