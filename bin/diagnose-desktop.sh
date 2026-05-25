#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Desktop-backend forensic report (RDR-001 Phase 3 Step 3, rr-2pp.4.3). Driven by
# the `diagnose` skill for backend:"desktop" runs. READ-ONLY — gathers facts and
# soft verdicts; never applies fixes, never gates anything.
#
#   diagnose-desktop.sh <session> [spec.json]
#
# Surfaces, per the RDR §Diagnose path:
#   (a) checkpoint coverage   — which expected checkpoints were called / missed,
#                               and whether the turn_end was genuine or a
#                               fallback-synthesized one (rr-2pp.4.2)
#   (b) soft-miss trend       — rate over the last N desktop runs + this session
#   (c) capture coverage      — .mov duration vs the transcript's tool-call span
#   (d) bridge-log liveness   — the per-MCPB log as a coarse liveness signal
#                               (001-research-20: goes quiet -> bridge may have
#                               crashed); per-server log only, transport-level
#
# HAR / Playwright-trace forensics are intentionally absent — the AX pivot has no
# CDP transport (RDR §Diagnose path).
#
# Artifact locations honour the same overrides as the writers so this is
# testable: RIG_TMP (session artifacts, prod /tmp), RIG_QUALITY_LOG (quality
# log), RIG_CLAUDE_LOGS_DIR (Claude per-server logs, prod ~/Library/Logs/Claude).
set -uo pipefail

SESSION="${1:-}"
SPEC="${2:-}"
if [[ -z "$SESSION" ]]; then
  echo "usage: diagnose-desktop.sh <session> [spec.json]" >&2
  exit 2
fi
# Validate SESSION before interpolating it into artifact paths, matching the
# writers (lib/sentinels.sh:_require_session, record.sh). A mistyped session
# like "../other" should fail loud, not silently read an unintended path.
if [[ ! "$SESSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "diagnose-desktop: SESSION must match [A-Za-z0-9._-]+ — got: $SESSION" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/quality.sh"

TMP="${RIG_TMP:-/tmp}"
TRANSCRIPT="$TMP/${SESSION}.bridge-transcript.jsonl"
MOV="$TMP/${SESSION}.mov"
RIG_CONFIG="$TMP/${SESSION}.rig-config.json"
LOGS_DIR="${RIG_CLAUDE_LOGS_DIR:-$HOME/Library/Logs/Claude}"
# Log filename uses the manifest display_name (001-research-4); read it so the
# two never drift, with a constant fallback if the manifest is unreadable.
DISPLAY_NAME="$(jq -r '.display_name // "Recording Rig Bridge"' "$HERE/bridge/manifest.json" 2>/dev/null || echo "Recording Rig Bridge")"
BRIDGE_LOG="$LOGS_DIR/mcp-server-${DISPLAY_NAME}.log"

# jq program fragment: parse an NDJSON file (transcript or quality log) into an
# array of object entries, dropping malformed/partial lines (mirrors
# lib/quality.sh). A truncated line must NOT abort the report — a strict `jq -s`
# would, and section (a) would then print a FALSE "all required checkpoints
# called". Concatenate with the rest of the program:
#   jq -Rrs "$NDJSON_OBJ_ARRAY"' | <rest>' "$FILE"
NDJSON_OBJ_ARRAY='[ split("\n")[] | select(length>0) | (try fromjson) | objects ]'

# Parse an ISO8601Z timestamp (fractional seconds tolerated) to epoch seconds.
# BSD date (macOS-only backend); prints nothing on a parse failure.
_iso_to_epoch() {
  local iso="${1%%.*}"; iso="${iso%Z}"
  date -j -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null || true
}

echo "[diagnose-desktop] session=${SESSION} backend=desktop"

# --- artifacts -------------------------------------------------------------
echo "--- artifacts ---"
TX_COUNT=0
if [[ -s "$TRANSCRIPT" ]]; then
  TX_COUNT="$(jq -Rrs "$NDJSON_OBJ_ARRAY"' | length' "$TRANSCRIPT" 2>/dev/null || echo 0)"
  echo "transcript: $TRANSCRIPT (${TX_COUNT} entries)"
else
  echo "transcript: MISSING ($TRANSCRIPT) — the bridge was never reached (no rig_* tool called)"
fi
if [[ -s "$MOV" ]]; then
  echo "mov:        $MOV ($(wc -c < "$MOV" | tr -d ' ') bytes)"
else
  echo "mov:        MISSING ($MOV)"
fi
[[ -f "$RIG_CONFIG" ]] && echo "rig-config: present" || echo "rig-config: MISSING"
[[ -n "$SPEC" ]] && echo "spec:       $SPEC" || echo "spec:       (not provided)"

# --- (a) checkpoint coverage ----------------------------------------------
echo "--- (a) checkpoint coverage ---"
if [[ -z "$SPEC" || ! -f "$SPEC" ]]; then
  echo "checkpoint coverage skipped (no spec provided) — pass the spec as arg 2 to enable"
elif [[ ! -s "$TRANSCRIPT" ]]; then
  echo "checkpoint coverage skipped (no transcript)"
else
  # Names the model actually checkpointed, in call order (parsed once, reused).
  CALLED_JSON="$(jq -Rrs "$NDJSON_OBJ_ARRAY"' | map(select(.tool=="rig_checkpoint") | .args.name)' "$TRANSCRIPT" 2>/dev/null || echo "[]")"
  CALLED="$(printf '%s' "$CALLED_JSON" | jq -r 'join(" ")' 2>/dev/null || echo "")"
  echo "expected: $(jq -r '[ (.desktop.checkpoints // [])[] | "\(.name)\(if .required then "(required)" else "" end)" ] | join(" ")' "$SPEC" 2>/dev/null)"
  echo "called:   ${CALLED:-(none)}"
  # Missing REQUIRED checkpoints (the gate-relevant set) — from the called set + spec.
  MISSING="$(jq -rn --argjson called "$CALLED_JSON" --slurpfile spec "$SPEC" '
      [ ($spec[0].desktop.checkpoints // [])[] | select(.required) | .name
        | select( . as $n | ($called | index($n)) | not ) ]
      | join(" ")' 2>/dev/null || echo "")"
  if [[ -n "$MISSING" ]]; then
    echo "MISSING REQUIRED: $MISSING"
  else
    echo "complete: all required checkpoints called"
  fi
  # turn_end: genuine, synthesized fallback (rr-2pp.4.2), or absent.
  TE="$(jq -Rrs "$NDJSON_OBJ_ARRAY"' | map(select(.tool=="rig_turn_end")) | last
        | if . == null then "absent"
          elif (.result.synthesized == true) then "synthesized"
          else "genuine" end' "$TRANSCRIPT" 2>/dev/null || echo "absent")"
  case "$TE" in
    synthesized) echo "turn_end: present (synthesized) — model skipped it; record.sh synthesized the fallback (soft miss)" ;;
    genuine)     echo "turn_end: present (genuine) — model closed the turn itself" ;;
    *)           echo "turn_end: ABSENT — the turn never closed (validator FAILs; no GIF)" ;;
  esac
fi

# --- (b) soft-miss trend ---------------------------------------------------
echo "--- (b) soft-miss trend ---"
QLOG="$(quality_log_path)"
read -r SMR_PCT SMR_N < <(quality_soft_miss_rate "$QLOG" 20)
echo "rate: ${SMR_PCT}% over last ${SMR_N} desktop runs (log: $QLOG)"
if [[ -s "$QLOG" ]]; then
  THIS="$(jq -Rrs --arg s "$SESSION" "$NDJSON_OBJ_ARRAY"' | map(select(.session==$s)) | last
      | if . == null then "none"
        else "soft_miss=\(.soft_miss) validate_pass=\(.validate_pass) idle_rc=\(.idle_rc)" end' \
      "$QLOG" 2>/dev/null || echo "none")"
  if [[ "$THIS" == "none" || -z "$THIS" ]]; then
    echo "this-session: no quality.jsonl entry for this session"
  else
    echo "this-session: $THIS"
  fi
else
  echo "this-session: no quality.jsonl entry for this session"
fi
if (( SMR_N >= 3 )) && (( SMR_PCT > 20 )); then
  echo "verdict: soft-miss rate >20% — instruction drift; strengthen the prologue (RDR-001 Risk 'instruction drift')"
fi

# --- (c) capture coverage --------------------------------------------------
echo "--- (c) capture coverage ---"
SPAN="unknown"
if [[ -s "$TRANSCRIPT" ]]; then
  # First/last tool-call timestamps in one tolerant pass ("-" when absent).
  read -r FIRST_TS LAST_TS < <(jq -Rrs "$NDJSON_OBJ_ARRAY"' | "\(.[0].ts // "-") \(.[-1].ts // "-")"' "$TRANSCRIPT" 2>/dev/null || echo "- -")
  if [[ "$FIRST_TS" != "-" && "$LAST_TS" != "-" ]]; then
    FE="$(_iso_to_epoch "$FIRST_TS")"; LE="$(_iso_to_epoch "$LAST_TS")"
    [[ -n "$FE" && -n "$LE" ]] && SPAN=$(( LE - FE ))
  fi
fi
echo "transcript_span_s: $SPAN"
if [[ ! -s "$MOV" ]]; then
  echo "mov_duration_s: (mov MISSING) — capture produced no .mov; the SCStream/AVAssetWriter path failed"
  echo "verdict: NO CAPTURE"
elif ! command -v ffprobe >/dev/null 2>&1; then
  echo "mov_duration_s: (ffprobe unavailable — install ffmpeg to enable the capture-coverage check)"
  echo "verdict: unknown (no ffprobe)"
else
  DUR="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$MOV" 2>/dev/null || echo "")"
  echo "mov_duration_s: ${DUR:-unknown}"
  if [[ -n "$DUR" && "$SPAN" != "unknown" ]]; then
    # awk: float-safe comparison. A .mov much shorter than the tool-call span
    # means the capture stopped before the turn finished.
    awk -v d="$DUR" -v w="$SPAN" 'BEGIN{
      printf "delta_s: %.2f\n", d - w;
      if (d < 1) print "verdict: CAPTURE EMPTY (mov ~0s)";
      else if (d < w) print "verdict: CAPTURE GAP (mov shorter than the tool-call span)";
      else print "verdict: ok (mov brackets the tool-call span)";
    }'
  fi
fi

# --- (d) bridge-log liveness ----------------------------------------------
echo "--- (d) bridge-log liveness ---"
echo "log: $BRIDGE_LOG"
if [[ -f "$BRIDGE_LOG" ]]; then
  LOG_MTIME="$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$BRIDGE_LOG" 2>/dev/null || echo unknown)"
  echo "status: present (mtime=${LOG_MTIME}, $(wc -c < "$BRIDGE_LOG" | tr -d ' ') bytes)"
  echo "last-lines:"
  tail -n 3 "$BRIDGE_LOG" 2>/dev/null | sed 's/^/  /'
  echo "note: per-server log carries transport lifecycle only (open/close); a quiet log during an active session may mean the bridge crashed (001-research-20)"
else
  echo "status: NOT FOUND — the bridge never connected in this profile, or logs are under a different dir than $LOGS_DIR"
fi

# --- forensics excluded ----------------------------------------------------
echo "--- forensics excluded ---"
echo "HAR / Playwright-trace: N/A (AX pivot — no CDP transport; RDR §Diagnose path)"

exit 0
