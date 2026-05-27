#!/usr/bin/env bash
# Top-level entry point. Read a spec, drive a recording, validate, render GIF.
# Usage: record.sh <spec.json>
# Env overrides: SESSION, CAST_OUT, GIF_OUT, SKIP_VALIDATE, SKIP_GIF,
#                ATTACH_GAP_SEC, SKIP_CONSENT_SWEEP, RIG_ALLOW_COMPETING_CLAUDE,
#                SKIP_STAGE_MANAGER_TOGGLE
set -euo pipefail

SPEC_ARG="${1:?usage: record.sh <spec.json>}"
SPEC="$(cd "$(dirname "$SPEC_ARG")" && pwd)/$(basename "$SPEC_ARG")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/sentinels.sh"
# shellcheck disable=SC1091
source "$HERE/lib/quality.sh"
# shellcheck disable=SC1091
source "$HERE/lib/coordination.sh"
# shellcheck disable=SC1091
source "$HERE/lib/trusted-folders.sh"
# shellcheck disable=SC1091
source "$HERE/lib/competing-claude.sh"
# shellcheck disable=SC1091
source "$HERE/lib/stage-manager.sh"

# Dedicated tmux socket per session so the rig:
# (a) doesn't pollute the user's normal tmux server,
# (b) can be invoked inside an existing tmux session, and
# (c) survives nested rig invocations (outer + inner pick distinct sockets).
# Default socket name is "rig-<session>" — uniquely scoped to this run.
# Override with RIG_TMUX_SOCKET env var if you have a specific reason.
unset TMUX TMUX_PANE 2>/dev/null || true

# Bash 4+ required (the driver and tmux-session use array idioms / read loops
# that work on bash 3.2 too, but `read -t`, `wait -n`, and a few other 4+
# features may be added later; fail loudly now rather than half-silently).
if (( BASH_VERSINFO[0] < 4 )); then
  echo "record: bash 4+ required (have ${BASH_VERSION}); install via 'brew install bash' on macOS" >&2
  exit 2
fi

# Resolve session name. Precedence: spec.session → env SESSION → auto-gen.
# (Spec MUST win over inherited env so nested invocations — e.g. an outer
# rig's Bash tool launching this inner rig — don't accidentally reuse the
# outer's session id from inherited env.)
SESSION_FROM_SPEC="$(jq -r '.session // empty' "$SPEC")"
if [[ -n "$SESSION_FROM_SPEC" ]]; then
  SESSION="$SESSION_FROM_SPEC"
elif [[ -z "${SESSION:-}" ]]; then
  SESSION="rig-$(date +%Y%m%d-%H%M%S)"
fi
if [[ ! "$SESSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "record: SESSION must match [A-Za-z0-9._-]+ — got: $SESSION" >&2
  exit 2
fi
export SESSION

# Backend selection (rr-2pp.3.3): cli (default, tmux+asciinema) or desktop
# (Claude.app via AX + ScreenCaptureKit, macOS only). The CLI path is unchanged.
BACKEND=$(jq -r '.backend // "cli"' "$SPEC")
case "$BACKEND" in
  cli|desktop) ;;
  *) echo "record: backend must be 'cli' or 'desktop' — got: $BACKEND" >&2; exit 2 ;;
esac

# Per-session tmux socket. Always derived from THIS run's SESSION — never
# inherited from the parent process, so nested rigs (outer record.sh →
# Bash tool → inner record.sh) each get their own isolated tmux server.
export RIG_TMUX_SOCKET="rig-$SESSION"
tmux() { command tmux -L "$RIG_TMUX_SOCKET" "$@"; }
export -f tmux

CAST_OUT="${CAST_OUT:-/tmp/${SESSION}.cast}"
GIF_OUT="${GIF_OUT:-/tmp/${SESSION}.gif}"
HOOKS_RENDERED="/tmp/${SESSION}.hooks.json"
# Desktop backend artifacts (the bridge writes the transcript; the driver the .mov).
ACTIVE_SESSION="/tmp/recording-rig.active-session"
RIG_CONFIG_OUT="/tmp/${SESSION}.rig-config.json"
MOV_OUT="/tmp/${SESSION}.mov"
MP4_OUT="/tmp/${SESSION}.mp4"
TRANSCRIPT_OUT="/tmp/${SESSION}.bridge-transcript.jsonl"

IDLE_SECONDS=$(jq -r '.pacing.idle_seconds // 8' "$SPEC")
EXIT_HOLD=$(jq -r '.pacing.exit_hold_sec // 8' "$SPEC")
ATTACH_GAP_SEC="${ATTACH_GAP_SEC:-$(jq -r '.pacing.attach_gap_sec // 3' "$SPEC")}"
AGENT_DONE_HOLD=$(jq -r '.pacing.agent_done_hold_sec // 4' "$SPEC")
TURN_TIMEOUT_SEC=$(jq -r '.pacing.turn_timeout_sec // 120' "$SPEC")
SESSION_MAX_SEC=$(jq -r '.pacing.session_max_sec // 1800' "$SPEC")

# Render-block (overrideable styling for agg). idle_time_limit is a render
# concern (GIF playback pacing), so it lives under .render — but we still
# accept .pacing.agg_idle_time_limit for backwards compatibility.
AGG_IDLE=$(jq -r '.render.idle_time_limit // .pacing.agg_idle_time_limit // 4' "$SPEC")
AGG_FONT_SIZE=$(jq -r '.render.font_size // 22' "$SPEC")
AGG_LINE_HEIGHT=$(jq -r '.render.line_height // 1.3' "$SPEC")
AGG_THEME=$(jq -r '.render.theme // "monokai"' "$SPEC")

export IDLE_SECONDS ATTACH_GAP_SEC TURN_TIMEOUT_SEC SESSION_MAX_SEC

# Preflight: tools (backend-specific — desktop doesn't need tmux/asciinema/agg/claude).
if [[ "$BACKEND" == "cli" ]]; then
  for bin in tmux jq asciinema agg claude node; do
    command -v "$bin" >/dev/null || { echo "missing prereq: $bin" >&2; exit 2; }
  done
else
  for bin in jq node ffmpeg; do
    command -v "$bin" >/dev/null || { echo "missing prereq: $bin" >&2; exit 2; }
  done
  [[ -x "$HERE/bin/desktop-driver" ]] || {
    echo "record: bin/desktop-driver missing — build it: bin/build-desktop-driver.sh" >&2; exit 2; }
  # Fail BEFORE launching the app if the driver's selectors file is absent (else
  # record.sh open -n's Claude-Rig and the driver only then dies at config load).
  [[ -f "$HERE/bin/desktop-ax-selectors.json" ]] || {
    echo "record: bin/desktop-ax-selectors.json missing" >&2; exit 2; }
  # render-webm is the post-capture render — checked here so a missing tool fails
  # before the recording runs, not after (review rr-2pp.3.3 #1).
  [[ -x "$HERE/bin/render-webm.sh" ]] || {
    echo "record: bin/render-webm.sh missing (rr-2pp.3.2)" >&2; exit 2; }
  # Every gate's for_command (when present) must name a real command, else the
  # bridge would silently match ANY command (scope-broadening). Fail loud.
  bad_fc=$(jq -r '
    ( .agent.commands // (if .agent.command then [.agent.command] else [] end) ) as $cmds
    | [ (.gates // [])[] | .for_command | select(. != null) | . as $fc | select(($cmds | index($fc)) == null) ]
    | join(", ")
  ' "$SPEC")
  [[ -z "$bad_fc" ]] || {
    echo "record: gates[].for_command references unknown command(s): $bad_fc" >&2; exit 2; }
fi

# Preflight: spec sanity — either a single-surface command(s) OR a multi-surface
# steps[] (rr-u07), each step carrying a non-empty command (matches SpecReader).
if ! jq -e '
  def has_cmd: (. // "") | (type == "string") and (length > 0);
  ((.agent.command // (.agent.commands // [])[0]) | has_cmd)
  or (((.steps | type) == "array") and ((.steps | length) > 0)
      and ((.steps | map(.command | has_cmd) | all)))
' "$SPEC" >/dev/null; then
  echo "record: spec must define agent.command / agent.commands, or a non-empty steps[] (each with a command)" >&2
  exit 2
fi

# Preflight: companion env $sentinel references must appear in wait_for_sentinels.
missing_waits=$(jq -r '
  (.companion // {}) as $c
  | ($c.env // {}) as $env
  | ($c.wait_for_sentinels // []) as $waits
  | [ $env | to_entries[]
      | select(.value | type == "string" and startswith("$"))
      | .value[1:]
      | select(. as $s | ($waits | index($s)) | not) ]
  | join(", ")
' "$SPEC")
if [[ -n "$missing_waits" ]]; then
  echo "record: companion.env references sentinels missing from wait_for_sentinels: $missing_waits" >&2
  exit 2
fi

# Preflight: validate every spec-provided identifier that flows into shell.
# (render-hooks.sh and tmux-session.sh each re-validate their own slice; this
# is the first-failure-fast layer that produces a clear preflight error.)
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  rig_check_identifier "hooks.capture_tools[].name" "$name" || exit 2
done < <(jq -r '(.hooks.capture_tools // []) | .[] | .name // ""' "$SPEC")
while IFS= read -r sent; do
  [[ -z "$sent" ]] && continue
  rig_check_identifier "companion.wait_for_sentinels[]" "$sent" || exit 2
done < <(jq -r '.companion.wait_for_sentinels // [] | .[]' "$SPEC")
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  rig_check_identifier "companion.env key" "$k" '^[A-Za-z_][A-Za-z0-9_]*$' || exit 2
done < <(jq -r '.companion.env // {} | keys[]' "$SPEC")

echo "[rig] session=$SESSION cast=$CAST_OUT gif=$GIF_OUT"

# Refuse to run if the spec path lives in the sentinel glob.
case "$SPEC" in
  /tmp/"$SESSION".*)
    echo "record: spec path $SPEC collides with sentinel glob /tmp/${SESSION}.* — move spec outside /tmp or rename" >&2
    exit 2
    ;;
esac

# --- EXIT trap: kill background processes and tmux session on any exit path.
# Declared here so it covers the consent-sweep below as well as the main flow.
# Variables expand at trap-fire time, so empty (unset) values become no-ops.
ASCIINEMA_PID=""
DRIVER_PID=""
WATCHER_PID=""
RIG_PID=""
STAGE_MGR_DISABLED=""  # set to 1 iff we disabled Stage Manager (cleanup restores it; rr-sm0)
cleanup() {
  local rc=$?
  for pid in "$DRIVER_PID" "$ASCIINEMA_PID" "$WATCHER_PID"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  # Desktop teardown: quit the Claude-Rig instance with SIGTERM (graceful — NEVER
  # SIGKILL/-9, which loses the install flush, P0.1) and unlink the active-session
  # pointer. No-ops for the CLI backend (RIG_PID empty, pointer absent).
  [[ -n "$RIG_PID" ]] && kill -TERM "$RIG_PID" 2>/dev/null || true
  rm -f "$ACTIVE_SESSION" 2>/dev/null || true
  # Restore Stage Manager if WE disabled it for this recording (rr-sm0). Runs on
  # EXIT/INT/TERM, so an interrupt never leaves the operator's Stage Manager off;
  # no-op for the CLI backend or when it was already off (flag empty).
  [[ -n "${STAGE_MGR_DISABLED:-}" ]] && stage_manager_set true 2>/dev/null || true
  # Kill the whole tmux server for this session's dedicated socket and
  # remove the socket file. Each rig run gets its own socket
  # (rig-<session>), so this is always safe — we never touch the user's
  # normal tmux server. tmux 3.x leaves the socket file on disk even
  # after the server exits, so we unlink it explicitly. Cover both
  # macOS (/private/tmp/tmux-<uid>) and Linux (/tmp/tmux-<uid>) layouts.
  tmux kill-server 2>/dev/null || true
  local uid; uid=$(id -u)
  rm -f "/private/tmp/tmux-${uid}/${RIG_TMUX_SOCKET}" \
        "/tmp/tmux-${uid}/${RIG_TMUX_SOCKET}" 2>/dev/null || true
  return $rc
}
trap cleanup EXIT INT TERM

# --- Consent sweep: dismiss the two interactive Claude consent dialogs that
# block SessionStart on first-run-per-machine and first-run-per-cwd. Runs in
# an auxiliary tmux session (NOT the recorded one) and uses bounded, one-shot
# screen-scrape — the only justified exception to the no-TUI-scraping rule.
# Skip with SKIP_CONSENT_SWEEP=1.
consent_sweep() {
  local bypass; bypass=$(jq -r '.agent.bypass_permissions // false' "$SPEC")
  local cwd_raw; cwd_raw=$(jq -r '.agent.cwd // "."' "$SPEC")
  local cwd; cwd=$(cd "$cwd_raw" 2>/dev/null && pwd) || return 0
  local aux="${SESSION}-warmup"
  local claude_args=()
  [[ "$bypass" == "true" ]] && claude_args+=(--dangerously-skip-permissions)
  claude_args+=(--model haiku)

  tmux kill-session -t "$aux" 2>/dev/null || true
  tmux new-session -d -s "$aux" -x 120 -y 40 -c "$cwd" \
    "claude $(printf '%q ' "${claude_args[@]}")"

  local accepted_legal=0 accepted_trust=0
  for ((i=0; i<25; i++)); do
    sleep 1
    local pane
    pane=$(tmux capture-pane -t "$aux" -p 2>/dev/null || echo "")
    if (( accepted_legal == 0 )) && echo "$pane" | grep -q "Yes, I accept"; then
      # Layout: "1. No, exit / 2. Yes, I accept" — Down + Enter selects option 2.
      tmux send-keys -t "$aux" Down
      sleep 0.3
      tmux send-keys -t "$aux" Enter
      accepted_legal=1
      sleep 2
      continue
    fi
    if (( accepted_trust == 0 )) && echo "$pane" | grep -q "trust this folder"; then
      # Layout: "1. Yes, I trust this folder / 2. No, exit" — Enter selects #1.
      tmux send-keys -t "$aux" Enter
      accepted_trust=1
      sleep 2
      continue
    fi
    # Normal prompt visible → consent has been cleared (or was never asked).
    # Match both bypass-mode signals AND a generic prompt-ready marker (the
    # claude version banner) so non-bypass recordings also break out cleanly.
    if echo "$pane" | grep -qE "bypass permissions on|cycle\)|Welcome back|Claude Code v[0-9]"; then
      break
    fi
  done

  tmux send-keys -t "$aux" C-c 2>/dev/null || true
  sleep 1
  tmux kill-session -t "$aux" 2>/dev/null || true
  echo "[rig] consent-sweep done (legal=$accepted_legal trust=$accepted_trust)"
}

# Refuse if another rig run owns this session. CLI: tmux-session.sh would
# kill-session the live one, corrupting both runs. Desktop: the GLOBAL
# active-session pointer can only name one run at a time. Check BEFORE the
# consent sweep so a conflict aborts cheaply.
if [[ "$BACKEND" == "cli" ]]; then
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "record: tmux session '$SESSION' already exists — another rig instance may be running" >&2
    echo "  (kill it with: tmux kill-session -t $SESSION)" >&2
    exit 2
  fi
elif [[ -e "$ACTIVE_SESSION" ]]; then
  echo "record: $ACTIVE_SESSION exists — another desktop rig may be running" >&2
  echo "  (remove it with: rm -f $ACTIVE_SESSION)" >&2
  exit 2
fi

# Consent sweep is CLI-only: it warms up the `claude` CLI first-run dialogs. The
# desktop Claude.app profile is logged in once, out of band.
if [[ "$BACKEND" == "cli" && "${SKIP_CONSENT_SWEEP:-0}" != "1" ]]; then
  consent_sweep
fi

# Clear stale sentinels BEFORE writing rig artifacts under /tmp/${SESSION}.*.
sentinel_clear_all

# --- Desktop backend (macOS): Claude.app via AX + ScreenCaptureKit. record.sh
# owns the launch, the active-session/rig-config writes, and the turn-end watch;
# bin/desktop-driver owns AX-drive + capture. RUNTIME-GATED by rr-2pp.3.6 — the
# Electron PID resolution + app lifecycle here are validated against the live
# Claude-Rig. Runs and exits before the (unchanged) CLI flow below.
if [[ "$BACKEND" == "desktop" ]]; then
  CLAUDE_RIG_DIR="$HOME/Library/Application Support/Claude-Rig"

  # rig-config: translate each gate's for_command (a command STRING in specs /
  # bin/driver.sh) to the INTEGER command index the bridge expects (bridge/
  # server.js); omit when absent (matches any command). Atomic .partial+rename.
  jq -c --arg sess "$SESSION" '
    ( .agent.commands // (if .agent.command then [.agent.command] else [] end) ) as $cmds
    | { session: $sess,
        gates: [ (.gates // [])[]
          | (.for_command // null) as $fc
          | { answer_index: (.answer_index // 1) }
            + ( if $fc == null then {}
                else ($cmds | index($fc)) as $i
                     | (if $i == null then {} else { for_command: $i } end)
                end ) ] }
  ' "$SPEC" > "${RIG_CONFIG_OUT}.partial"
  mv "${RIG_CONFIG_OUT}.partial" "$RIG_CONFIG_OUT"

  # active-session pointer: single-line id, NO trailing newline; atomic.
  printf '%s' "$SESSION" > "${ACTIVE_SESSION}.partial"
  mv "${ACTIVE_SESSION}.partial" "$ACTIVE_SESSION"
  echo "[rig] desktop: active-session=$SESSION rig-config=$RIG_CONFIG_OUT"

  # Coordination provider per surface (RDR-001 §Technical Design, amended
  # 2026-05-25): Chat/Code -> mcp-bridge (the sentinel watch below, unchanged);
  # CoWork -> agent-transcript-tail (audit.jsonl {type:result}). surface is a
  # TOP-LEVEL spec field (matches SpecReader.swift); coordination defaults to auto.
  COORD_OVERRIDE=$(jq -r '.coordination // "auto"' "$SPEC" 2>/dev/null || echo "auto")
  LAMS_ROOT="$CLAUDE_RIG_DIR/local-agent-mode-sessions"

  # Per-step surfaces (rr-u07 multi-surface choreography). Mirrors SpecReader's
  # synthesis: an explicit top-level steps[] wins; otherwise one step per command
  # on the single `surface`. record.sh owns coordination, so it derives the surface
  # PER STEP here — used for the gate preflight and the per-step turn-end watch. The
  # driver's announced steps-total is cross-checked against this count below.
  mapfile -t STEP_SURFACES < <(jq -r '
    if (.steps? | type) == "array" and (.steps | length) > 0 then
      .steps[] | (.surface // "chat")
    else
      ( .surface // "chat" ) as $s
      | ( if (.agent.commands? | type) == "array"
          then [ .agent.commands[] | select(. != "" and . != null) ] else [] end ) as $cmds
      | ( if ($cmds | length) > 0 then ($cmds | length)
          elif ((.agent.command // "") | length) > 0 then 1
          else 0 end ) as $n
      | range(0; $n) | $s
    end' "$SPEC" 2>/dev/null)
  (( ${#STEP_SURFACES[@]} > 0 )) || { echo "record: spec has no steps[] and no agent.command(s)" >&2; exit 1; }
  SURFACE=$(IFS=+; echo "${STEP_SURFACES[*]}")   # display / quality-log (e.g. code+chat+cowork)

  # Resolve each step's provider; track whether ANY step uses the bridge (its
  # transcript is then the validate target — it carries the spec's gates[] and
  # required checkpoints, produced by the bridge steps).
  USED_BRIDGE=0
  declare -a STEP_PROVIDERS=()
  for _sfc in "${STEP_SURFACES[@]}"; do
    _prov=$(coordination_provider_for_surface "$_sfc" "$COORD_OVERRIDE") \
      || { echo "record: could not resolve coordination provider for surface '$_sfc'" >&2; exit 1; }
    STEP_PROVIDERS+=("$_prov")
    [[ "$_prov" == "mcp-bridge" ]] && USED_BRIDGE=1
  done

  # Pessimistic-case preflight (rr-2pp.5.4), generalized to multi-surface: gates[]
  # and required checkpoints are carried by the bridge + its transcript, so a run
  # with ANY bridge step can carry them. Only a recording whose every step uses a
  # fallback provider (no bridge at all) cannot — reject such a spec BEFORE launch.
  if (( USED_BRIDGE == 0 )); then
    coordination_preflight_gates "agent-transcript-tail" "$SPEC" || exit 2
  fi
  echo "[rig] desktop: steps=${#STEP_SURFACES[@]} surfaces=$SURFACE used_bridge=$USED_BRIDGE"

  # Code-surface trusted-folder pre-seeding (rr-2pp.5.3): merge the spec's
  # desktop.trusted_folders into the profile config so local-agent-mode does not
  # gate on the per-folder trust dialog mid-recording. Done BEFORE launch so the
  # app reads the seeded value at startup. Seeded unconditionally: the key is
  # ignored by the Chat/CoWork surfaces, so there is no need to branch on surface.
  mapfile -t TRUSTED_FOLDERS < <(jq -r '(.desktop.trusted_folders // [])[]' "$SPEC" 2>/dev/null || true)
  if (( ${#TRUSTED_FOLDERS[@]} > 0 )); then
    if trusted_folders_seed "$CLAUDE_RIG_DIR/config.json" "${TRUSTED_FOLDERS[@]}"; then
      echo "[rig] desktop: pre-seeded ${#TRUSTED_FOLDERS[@]} trusted folder(s) into config.json"
    else
      echo "record: warning — trusted-folder pre-seed failed (Code may prompt mid-recording)" >&2
    fi
  fi

  # Competing-instance guard (rr-re6): refuse if a NON-Rig Claude.app instance is
  # running. macOS activates per bundle, so a second Claude.app instance keeps the
  # foreground when `open -n -a Claude` launches the Rig instance below — the Rig
  # window stays backgrounded, its Chromium accessibility tree never materializes,
  # and the driver's armWait times out. (Confirmed by Test A: zero competing mains
  # => hands-free.) The user's primary holds live work, so we REFUSE, never quit
  # it. Override with RIG_ALLOW_COMPETING_CLAUDE=1 (expert/escape hatch).
  if [[ "${RIG_ALLOW_COMPETING_CLAUDE:-}" != "1" ]]; then
    mapfile -t _COMPETING_CLAUDE < <(ps -axo pid=,command= | competing_claude_pids "$CLAUDE_RIG_DIR")
    if (( ${#_COMPETING_CLAUDE[@]} > 0 )); then
      echo "record: a competing Claude.app instance is running (pid(s): ${_COMPETING_CLAUDE[*]}) — quit it first (⌘Q)." >&2
      echo "        A second Claude.app bundle instance keeps macOS foreground, so the Claude-Rig" >&2
      echo "        instance record.sh launches stays backgrounded and its accessibility tree never" >&2
      echo "        loads (the desktop driver then times out). Quit your other Claude.app and re-run," >&2
      echo "        or set RIG_ALLOW_COMPETING_CLAUDE=1 to override." >&2
      exit 1
    fi
  fi

  # Single-active-session guard (mirrors the CLI rig's tmux has-session check). A
  # second concurrent instance collides — the driver may attach to the wrong one
  # and stall (observed during rr-2pp.5.5 bring-up). But our OWN previous run (in
  # a back-to-back loop) is still shutting down after its EXIT-trap SIGTERM, so
  # WAIT for any existing main instance to quit before refusing — only a foreign
  # or stuck instance that outlives the wait is fatal. The MAIN process carries
  # --user-data-dir=<rig> but NOT --type= (Electron helpers do).
  rig_main_pid() {
    local p
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      ps -o command= -p "$p" 2>/dev/null | grep -q -- "--type=" || { printf '%s' "$p"; return 0; }
    done < <(pgrep -f -- "--user-data-dir=$CLAUDE_RIG_DIR" 2>/dev/null || true)
    return 1
  }
  RIG_QUIT_WAIT="${RIG_QUIT_WAIT:-30}"
  _waited=0
  while p="$(rig_main_pid || true)"; [[ -n "$p" ]]; do
    (( _waited == 0 )) && echo "[rig] desktop: waiting for an existing Claude-Rig instance (pid $p) to quit..."
    if (( _waited >= RIG_QUIT_WAIT )); then
      echo "record: a Claude-Rig instance (pid $p) is still running after ${_waited}s — quit it first (⌘Q)." >&2
      echo "        record.sh launches its own clean instance; a second one collides and the driver" >&2
      echo "        may attach to the wrong process. (Raise RIG_QUIT_WAIT if teardown is just slow.)" >&2
      exit 1
    fi
    sleep 2
    _waited=$((_waited + 2))
  done
  (( _waited > 0 )) && echo "[rig] desktop: prior instance gone after ${_waited}s; launching."

  # Disable Stage Manager for the recording (rr-sm0). It repositions/animates the Rig
  # window on the focus changes between surface switches, which corrupts the capture
  # (ScreenCaptureKit is locked to the step-0 window and follows it as it shrinks). Do
  # it BEFORE launch; remember we did so cleanup() restores it (even on interrupt).
  # Skip with SKIP_STAGE_MANAGER_TOGGLE=1. No-op when already off / not configured.
  if [[ "${SKIP_STAGE_MANAGER_TOGGLE:-0}" != "1" ]] && stage_manager_is_enabled; then
    if stage_manager_set false; then
      STAGE_MGR_DISABLED=1
      echo "[rig] desktop: Stage Manager disabled for the recording (restored on exit)"
    else
      echo "record: warning — could not disable Stage Manager; capture may be affected on surface switches" >&2
    fi
  fi

  # Launch the isolated profile. NEVER --remote-debugging-* (the app guard quits).
  open -n -a Claude --args \
    --user-data-dir="$CLAUDE_RIG_DIR" \
    --force-renderer-accessibility
  sleep "$ATTACH_GAP_SEC"

  # Resolve the Claude-Rig MAIN pid: it carries --user-data-dir=<rig> but not
  # --type= (Electron helpers do). RUNTIME-WATCH (rr-2pp.3.6): confirm this is
  # the AX-attachable main process, not a helper.
  RIG_PID=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if ! ps -o command= -p "$p" 2>/dev/null | grep -q -- "--type="; then
      RIG_PID="$p"; break
    fi
  done < <(pgrep -f -- "--user-data-dir=$CLAUDE_RIG_DIR" 2>/dev/null || true)
  [[ -n "$RIG_PID" ]] || { echo "record: could not resolve Claude-Rig pid" >&2; exit 1; }
  echo "[rig] desktop: Claude-Rig pid=$RIG_PID"

  # Driver: AX-drive + capture. Announces steps-total, then drives each step and
  # writes step-K-submitted; waits on step-K-done (per step) + agent-done (final).
  "$HERE/bin/desktop-driver" --pid "$RIG_PID" --spec "$SPEC" &
  DRIVER_PID=$!

  # Per-step turn-end watch (rr-u07). record.sh still owns turn-end detection (RDR
  # L169); it now loops over the driver's steps, running the watch for EACH step's
  # surface provider — mcp-bridge is the existing sentinel_wait_idle (byte-identical
  # for a single bridge step); agent-transcript-tail tails audit.jsonl. The handshake:
  # the driver writes step-K-submitted, record.sh writes step-K-done, repeat; then
  # agent-done is the final flush signal. SOFT_MISS aggregates across steps.
  driver_alive() { kill -0 "$DRIVER_PID" 2>/dev/null; }

  # The driver announces how many steps it will drive; cross-check against our own
  # spec read so a SpecReader/jq synthesis drift is caught before it desyncs.
  STEPS_TOTAL=0
  _w=0
  while [[ ! -s "$(sentinel_path steps-total)" ]]; do
    driver_alive || { echo "record: driver exited before announcing steps-total" >&2; break; }
    (( _w >= 60 )) && { echo "record: driver never announced steps-total (60s)" >&2; break; }
    sleep 1; _w=$((_w + 1))
  done
  STEPS_TOTAL="$(cat "$(sentinel_path steps-total)" 2>/dev/null || echo 0)"
  [[ "$STEPS_TOTAL" =~ ^[0-9]+$ ]] || STEPS_TOTAL=0
  if (( STEPS_TOTAL != ${#STEP_SURFACES[@]} )); then
    echo "record: step-count mismatch — driver=$STEPS_TOTAL record.sh=${#STEP_SURFACES[@]}; aborting coordination" >&2
    STEPS_TOTAL=0
  fi

  SOFT_MISS=0
  IDLE_RC=0
  for (( _k = 0; _k < STEPS_TOTAL; _k++ )); do
    # Wait (bounded, with driver-liveness) for the driver to submit step _k.
    _w=0
    while [[ ! -e "$(sentinel_path "step-${_k}-submitted")" ]]; do
      driver_alive || { echo "record: driver exited before step $_k submit" >&2; break; }
      (( _w >= SESSION_MAX_SEC )) && { echo "record: step $_k never submitted (${SESSION_MAX_SEC}s)" >&2; break; }
      sleep 1; _w=$((_w + 1))
    done
    [[ -e "$(sentinel_path "step-${_k}-submitted")" ]] || break  # gave up -> stop coordinating

    _provider="${STEP_PROVIDERS[$_k]}"
    # Consecutive bridge steps SHARE the turn-end sentinel — clear it now (after this
    # step's submit) so the idle-watch waits for THIS step's fresh rig_turn_end, not
    # the previous bridge step's stale one (whose old mtime reads as already-idle and
    # returns immediately, skipping the turn). The transcript is NOT cleared, so every
    # step's checkpoints accumulate for validation. (rr-u07 multi-bridge-step fix.)
    [[ "$_provider" == "mcp-bridge" ]] && rm -f "$(sentinel_path turn-end)"
    # Baseline AFTER this step's submit: only an audit.jsonl modified at/after now
    # is this step's turn-end candidate (agent-transcript-tail). Empty for mcp-bridge.
    STEP_BASELINE=$(coordination_ready "$_provider")
    _rc=0
    coordination_wait_turn_end "$_provider" "$IDLE_SECONDS" "$TURN_TIMEOUT_SEC" "$SESSION_MAX_SEC" \
      "$LAMS_ROOT" "$STEP_BASELINE" || _rc=$?
    (( _rc != 0 )) && IDLE_RC=$_rc  # remember the last non-zero for the quality log
    # rc 2 = soft miss (turn_timeout, no turn-end progress). Synthesis is mcp-bridge
    # only (it validates the bridge transcript); a fallback rig_turn_end there lets
    # the run COMPLETE instead of hard-failing. Best-effort — never abort (the EXIT
    # trap would SIGTERM the driver mid-flush). Other rc != 0 -> not settled cleanly.
    if (( _rc == 2 )); then
      SOFT_MISS=1
      if [[ "$_provider" == "mcp-bridge" && -s "$TRANSCRIPT_OUT" ]]; then
        if quality_synthesize_turn_end "$TRANSCRIPT_OUT" "$SESSION"; then
          echo "[rig] desktop: step $_k SOFT MISS — synthesized fallback turn-end" >&2
        else
          echo "[rig] desktop: step $_k SOFT MISS — fallback synthesis FAILED" >&2
        fi
      else
        echo "[rig] desktop: step $_k SOFT MISS ($_provider)" >&2
      fi
    elif (( _rc != 0 )); then
      echo "record: step $_k turn-end did not settle cleanly (rc=$_rc)" >&2
    fi
    touch "$(sentinel_path "step-${_k}-done")"  # advance the driver to step _k+1
  done
  touch "$(sentinel_path agent-done)"  # final flush signal to the driver
  wait "$DRIVER_PID" 2>/dev/null || true
  DRIVER_PID=""
  echo "[rig] desktop: capture complete -> $MOV_OUT"

  # Validate target (rr-u07). If ANY step used the bridge, validate the bridge
  # transcript — it carries those steps' checkpoints + rig_turn_end (for the
  # multi-surface tier demo: the Code/Chat steps). Only when EVERY step is
  # agent-transcript-tail do we validate the last step's audit.jsonl (the
  # single-surface CoWork case, unchanged). Captured BEFORE branching so every
  # desktop run lands one quality.jsonl entry.
  VALIDATE_INPUT="$TRANSCRIPT_OUT"
  if (( USED_BRIDGE == 0 )); then
    AUDIT_INPUT="$(coordination_transcript_path "agent-transcript-tail" "$LAMS_ROOT" "${STEP_BASELINE:-0}" 2>/dev/null || true)"
    if [[ -n "$AUDIT_INPUT" ]]; then
      VALIDATE_INPUT="$AUDIT_INPUT"
      echo "[rig] desktop: validating against audit.jsonl -> $VALIDATE_INPUT"
    else
      echo "[rig] desktop: WARN — no audit.jsonl resolved; validate will report the miss" >&2
    fi
  fi
  VALIDATE_PASS=0
  if node "$HERE/bin/validate.mjs" "$SPEC" "$VALIDATE_INPUT" "$MOV_OUT"; then
    VALIDATE_PASS=1
  fi

  # Soft-miss aggregation: one entry per desktop run (rr-2pp.4.2). Desktop-only —
  # the CLI path stays byte-identical (rr-2pp.4.4). SURFACE was resolved above.
  quality_log_append "$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
    --arg session "$SESSION" \
    --arg spec "$SPEC" \
    --arg surface "$SURFACE" \
    --argjson soft_miss "$SOFT_MISS" \
    --argjson validate_pass "$VALIDATE_PASS" \
    --argjson idle_rc "$IDLE_RC" \
    '{ts:$ts, session:$session, spec:$spec, backend:"desktop", surface:$surface,
      soft_miss:($soft_miss==1), validate_pass:($validate_pass==1), idle_rc:$idle_rc}')"

  # Render .mp4 + .gif, gated on PASS (a soft miss that validated still renders).
  if (( VALIDATE_PASS )); then
    if [[ "${SKIP_GIF:-0}" != "1" ]]; then
      "$HERE/bin/render-webm.sh" "$MOV_OUT" "$MP4_OUT" "$GIF_OUT"
      echo "[rig] desktop: rendered $GIF_OUT + $MP4_OUT"
    fi
  else
    echo "[rig] validation failed; refusing to render (override with SKIP_VALIDATE=1)" >&2
    exit 1
  fi
  exit 0
fi

# Render hooks.
"$HERE/bin/render-hooks.sh" "$SPEC" "$SESSION" "$HOOKS_RENDERED"
echo "[rig] hooks rendered -> $HOOKS_RENDERED"

# Spawn tmux session and capture the agent pane ID.
AGENT_PANE_ID=$("$HERE/bin/tmux-session.sh" "$SPEC" "$HOOKS_RENDERED")
if [[ -z "$AGENT_PANE_ID" ]]; then
  echo "record: tmux-session.sh did not emit agent pane id" >&2
  exit 1
fi
# Target the agent pane by its stable %N id — immune to active-pane shifts
# caused by a companion split-window AND to base-index/pane-base-index.
export TMUX_TARGET="$AGENT_PANE_ID"
echo "[rig] tmux session up; agent pane = $AGENT_PANE_ID"

# Watcher: terminates once either (a) all panes are dead, or (b) agent-done
# sentinel exists and AGENT_DONE_HOLD elapses.
(
  hold_remaining=""
  iter=0
  while :; do
    sleep 2
    iter=$((iter + 1))
    panes_output=$(tmux list-panes -t "$SESSION" -F '#{pane_dead}' 2>&1)
    panes_rc=$?
    alive=$(printf '%s\n' "$panes_output" | grep -c '^0$' 2>/dev/null || true)
    [[ "${RIG_WATCHER_DEBUG:-0}" == "1" ]] && \
      echo "[watcher iter=$iter rc=$panes_rc alive=$alive panes_output='${panes_output:0:80}']" >&2
    if [[ "$alive" == "0" ]]; then
      [[ "${RIG_WATCHER_DEBUG:-0}" == "1" ]] && echo "[watcher BREAK on alive=0]" >&2
      break
    fi
    if sentinel_exists agent-done; then
      if [[ -z "$hold_remaining" ]]; then
        hold_remaining="$AGENT_DONE_HOLD"
      else
        hold_remaining=$(( hold_remaining - 2 ))
        (( hold_remaining <= 0 )) && break
      fi
    fi
  done
  sleep "$EXIT_HOLD"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
) &
WATCHER_PID=$!

# Start asciinema first so it's capturing before the driver's first keystroke.
asciinema rec --overwrite --quiet \
  --output-format asciicast-v2 \
  --command "tmux -L $RIG_TMUX_SOCKET attach -t $SESSION" \
  "$CAST_OUT" &
ASCIINEMA_PID=$!

sleep "$ATTACH_GAP_SEC"

# Driver.
"$HERE/bin/driver.sh" "$SPEC" &
DRIVER_PID=$!

# Wait for asciinema to exit (watcher kills the session when work is done).
wait "$ASCIINEMA_PID" 2>/dev/null || true
wait "$DRIVER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true

# Clear PIDs so the EXIT trap's kill calls become no-ops (processes already gone).
ASCIINEMA_PID="" DRIVER_PID="" WATCHER_PID=""

echo "[rig] cast captured: $CAST_OUT"

# Validate, then render.
if node "$HERE/bin/validate.mjs" "$SPEC" "$CAST_OUT"; then
  if [[ "${SKIP_GIF:-0}" != "1" ]]; then
    agg --idle-time-limit "$AGG_IDLE" \
        --font-size "$AGG_FONT_SIZE" \
        --line-height "$AGG_LINE_HEIGHT" \
        --theme "$AGG_THEME" \
      "$CAST_OUT" "$GIF_OUT"
    echo "[rig] gif rendered: $GIF_OUT"
  fi
else
  echo "[rig] validation failed; refusing to render GIF (override with SKIP_VALIDATE=1)" >&2
  exit 1
fi
