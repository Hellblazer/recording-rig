---
name: author-spec
description: Interactively author a recording-rig spec JSON for a new tutorial/demo/screencast. Use when the user says "write a recording spec", "I want to record X", "set up a recording for <skill>", or "/recording-rig:author". Asks the backend first (CLI or macOS Desktop), then walks the user through the agent command, surface, gates/checkpoints, companion pane, and validation, and writes a valid spec file.
---

# author-spec

Turn a prose description of what the user wants to record into a working JSON spec.

## When to use

Trigger when the user describes a recording they want — even informally:

- "I want to record my new /foo command running"
- "Let's make a gif for the README of this skill"
- "Capture this two-pane demo where the agent kicks off a job and a watcher reports progress"
- "Record Claude.app Code creating a file" (Desktop backend)
- "/recording-rig:author"

## Backend (ask this FIRST, before anything else)

The backend decides the whole rest of the flow, so it is question zero:

- **CLI** (default) — headless `claude` in tmux, captured with asciinema → GIF. Cross-platform, deterministic, no live app. This is what most tutorials use.
- **Desktop** (macOS only) — the real Claude.app, driven over Accessibility and screen-recorded. Use only when the recording must show the desktop UI (Chat / Code / CoWork surfaces). Adds setup preconditions (below).

Spec field: omit `backend` (or `"cli"`) for CLI; `"backend": "desktop"` for Desktop.

If **CLI** → follow [CLI backend](#cli-backend--what-to-ask).
If **Desktop** → follow [Desktop backend](#desktop-backend-macos--what-to-ask).

## CLI backend — what to ask (in order — each as a separate `AskUserQuestion` if interactive)

1. **Session name.** Suggest a slug-cased default derived from the user's description. Must match `[A-Za-z0-9._-]+`.

2. **Recording shape** — pick one:
   - Single-pane (agent runs a command and replies)
   - Gated (agent calls `AskUserQuestion`, rig auto-answers a specific option)
   - Multi-command (agent runs commands in sequence across turns)
   - Two-pane (agent + companion observer process — companion subscribes to a sentinel emitted by a `PostToolUse` hook)

3. **Agent command(s).** The slash command(s) or prose prompt(s) to paste. Single string for shape 1/2; array for shape 3. Be explicit in the prompt — claude works best with "Reply with exactly one line: PREFIX=<answer>" style instructions.

4. **Working dir (`agent.cwd`).** Where the child claude session runs. Often the user's current project root.

5. **Bypass permissions?** Default yes for tutorial recordings (smoother flow). Spec field: `agent.bypass_permissions: true`.

6. **Model.** Default `haiku` for fast deterministic answers, `sonnet` for anything reasoning-heavy. Goes in `agent.extra_args: ["--model", "haiku"]`.

7. **Gates (shape 2 only).** For each gate: which option index to pick (1-based), pre/post Enter hold seconds. The rig sends `(N-1) × Down + Enter`.

8. **PostToolUse capture (shape 4 only).** Tool matcher regex (e.g. `^Bash$` or `^mcp__.*__start_job$`) and a jq expression to extract the ID/payload from `tool_response`. Sentinel name must match `[A-Za-z0-9._-]+`.

9. **Companion (shape 4 only).** Command + args. Environment vars referencing sentinels as `$sentinel-name`. List the sentinels in `wait_for_sentinels`.

10. **Validation assertions.** What strings prove the recording worked? Most important: pick strings that the agent emits but the prompt does NOT contain — otherwise the validator passes on the prompt echo. Use either `must_contain` (set check) or `must_contain_in_order` (sequence check). The `must_not_contain` default already covers `step_aborted` / `failure_reason`.

## Desktop backend (macOS) — what to ask

The Desktop backend drives the real Claude.app. Coordination is hook-free: the model
calls bridge tools (`rig_checkpoint`, `rig_turn_end`) that the `recording-rig-bridge`
MCP extension turns into sentinels, OR — on CoWork — the rig tails the agent transcript.
Validation runs against the **transcript JSONL**, not a cast.

0. **Probe-cache precondition (HARD GATE — do this before any other Desktop question).**
   The surfaces must have been validated against a live Claude-Rig recently. Check the
   probe cache freshness:

   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/desktop-doctor.sh"
   _desktop_cache_fresh "$RIG_PROBE_CACHE" 30 && echo FRESH || echo "STALE_OR_ABSENT: $RIG_PROBE_CACHE"
   ```

   If it is **not** `FRESH`, **STOP — do not author a Desktop spec.** Tell the user:

   > The Desktop surface probe cache is stale or absent. Launch Claude-Rig, then run
   > `"${CLAUDE_PLUGIN_ROOT}/bin/doctor.sh" --probe-surfaces` (it validates the live
   > surfaces; the cache must be < 30 days old). Then re-run `/recording-rig:author`.

   (The `--probe-surfaces` subcommand currently runs only via the shell path above — it
   is not yet wired through the `/recording-rig:doctor` slash command, see rr-edh.)

   Only continue once the cache is `FRESH`.

1. **Session name.** Same rule as CLI (`[A-Za-z0-9._-]+`).

2. **Surface** — pick one; each pins a coordination provider:
   - **chat** → provider `mcp-bridge`. Gates and required checkpoints supported.
   - **code** → provider `mcp-bridge`. Gates and required checkpoints supported. Also needs
     a trusted-folder seed + a one-time manual folder selection (see step 7).
   - **cowork** → provider `agent-transcript-tail`. **No gates and no _required_ checkpoints**
     reach this surface (the fallback provider carries neither). Plain single-turn tasks only.

   `surface` is a **top-level** spec field (NOT under `desktop`) — it matches `SpecReader.swift`.

3. **Agent command(s).** The prompt pasted into the composer. Same explicit-instruction
   guidance as CLI. (`agent.command` string, or `agent.commands[]` for multi-turn.)

4. **`system_prompt_prologue`** (top-level). Prepended to the first composer paste — Claude.app
   has no system-prompt flag, so this is how the model learns to call the rig tools.
   - **chat / code** — MUST lead with loading the bridge tools first (Claude.app v1.8555.2+
     lazy-loads MCP extension tools on demand; without this lead the model calls zero
     `rig_*` tools and the bridge transcript is empty — the rr-yfj regression). Starter:

     > `First, load the Recording Rig Bridge tools (rig_checkpoint, rig_turn_end) so they are available. Then <do the task>; right after <the asserted beat>, call the rig_checkpoint tool with name "<checkpoint>"; and as your final step call the rig_turn_end tool.`

   - **cowork** — NO bridge; turn-end is the transcript `{type:"result"}` line. The prologue is
     plain task framing only (often omit it entirely).
   - **Framing rule (all surfaces):** plain "please use these tools as you work" phrasing. NEVER
     a "you are being recorded" framing — it trips the model's injection-resistance and it refuses.

5. **`coordination`** (top-level). Default `"auto"` — resolves to the per-surface provider above.
   Only set it explicitly as an advanced override; otherwise leave it `auto` (or omit).

6. **`desktop.checkpoints[]`** — `{ "name": "<id>", "required": <bool> }`. `required:true` checkpoints
   must appear, in order, in the bridge transcript.
   - **cowork**: only **non-required** checkpoints are allowed — if the user wants a *required*
     checkpoint on CoWork, **refuse** and explain that `agent-transcript-tail` cannot assert it
     (offer chat/code instead, or drop `required`).

7. **Gates** — **chat / code only.** If the user wants a gate on **cowork**, **REFUSE at authoring**
   (do not write `gates[]`): mirror `record.sh`'s `coordination_preflight_gates`, which rejects a
   gate-bearing spec on the fallback provider before launch. Explain and offer chat/code instead.

8. **Code-surface extras (surface = code only).**
   - `desktop.trusted_folders: ["<abs path>"]` — seeds Claude.app's `localAgentModeTrustedFolders`
     so the per-folder trust dialog does not fire mid-recording.
   - **One-time manual setup the spec cannot do for them:** the Code working folder must be
     pre-selected once in the Code surface (the native folder picker is not AX-drivable; the
     selection persists in the profile). Tell the user to do this once before the first Code recording.

9. **Validation assertions.** Same agent-output-not-prompt-echo rule as CLI. For Desktop these run
   against the transcript JSONL. `must_contain` / `must_contain_in_order`; `must_not_contain`
   defaults still apply.

10. **Pacing.** Desktop needs `pacing.attach_gap_sec` (≈15s app-attach wait) and `exit_hold_sec`;
    `turn_timeout_sec` runs longer than CLI (chat ~120s, code ~180s, cowork ~300s). Use the example
    specs' pacing as the starting point.

## Critical correctness rules

CLI:

- **Validation strings must be agent-output, not prompt text.** If the user asks "validate against ANSWER=42", check whether "ANSWER=42" appears in the agent.command — if yes, suggest a more unique assertion (e.g. add a random suffix prefix like "RESULT-7K2F=" that's clearly emitted, not echoed).
- **`pre_enter_sec >= 1`.** The driver floors this at 1, but the spec author should pick 3-5s for human readability of the gate.
- **Sentinel names + env keys are shell-validated** — `[A-Za-z0-9._-]+` for sentinels, `[A-Za-z_][A-Za-z0-9_]*` for env keys. Reject anything else at authoring time.

Desktop (in addition):

- **Probe-cache hard gate.** Never author a Desktop spec without a `FRESH` probe cache (step 0).
- **CoWork carries neither gates nor required checkpoints.** Refuse both at authoring time rather than letting `record.sh` reject the spec at launch.
- **chat / code prologue MUST lead with loading the bridge tools** (rr-yfj / v1.8555.2 lazy-load).
- **`surface` is a top-level field**, not under `desktop` (matches `SpecReader.swift`).
- **Code needs a one-time manual folder pre-selection**; the spec only seeds *trust*, not the selection.

## Output

Write the spec to a path the user picks (default: `recordings/<session>.json` in the current project). After writing, suggest the next step:

```
Spec written to recordings/<session>.json. First verify prereqs, then run:
  ${CLAUDE_PLUGIN_ROOT}/bin/doctor.sh          # CLI; on Darwin also reports the Desktop checks
  ${CLAUDE_PLUGIN_ROOT}/bin/record.sh recordings/<session>.json
```

Reference the canonical examples for shape-matching:

CLI:

- `${CLAUDE_PLUGIN_ROOT}/examples/single-pane.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/gated.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/two-pane.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/multi-command.json`

Desktop:

- `${CLAUDE_PLUGIN_ROOT}/examples/desktop-chat.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/desktop-code.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/desktop-cowork.json`
