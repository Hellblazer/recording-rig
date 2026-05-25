#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Phase 2 MVV gate helper (rr-2pp.3.6). Run on the macOS HOST AFTER a desktop
# recording — `bin/record.sh examples/desktop-chat.json` — against the live
# Claude-Rig. Inspects the produced artifacts and runs the W1–W6 runtime
# watch-list checks from the rr-2pp.3.5 invariant review + the integration
# review (prologue delivery).
#
# Usage: desktop-gate-smoke.sh verify   [session]   # PASS/FAIL artifact gate
#        desktop-gate-smoke.sh diagnose [session]   # deep dump for a failure
#
# Default session: rig-example-desktop-chat (examples/desktop-chat.json).
set -uo pipefail

SESSION="${2:-rig-example-desktop-chat}"
MOV="/tmp/${SESSION}.mov"
GIF="/tmp/${SESSION}.gif"
MP4="/tmp/${SESSION}.mp4"
TRANSCRIPT="/tmp/${SESSION}.bridge-transcript.jsonl"
BRIDGE_LOG="$HOME/Library/Logs/Claude/mcp-server-Recording Rig Bridge.log"

fail=0
ok()  { printf '  ✓  %s\n' "$1"; }
no()  { printf '  ✗  %s\n' "$1"; fail=$((fail + 1)); }

case "${1:-}" in
  verify)
    echo "[gate] verifying desktop artifacts for session=$SESSION"

    # .mov + W5: were frames actually appended (SCK BGRA -> h264)? A 0-frame
    # .mov is the W5 failure mode (the highest-risk runtime concern).
    if [[ -f "$MOV" ]]; then
      frames=$(ffprobe -v error -count_frames -select_streams v:0 \
        -show_entries stream=nb_read_frames -of default=nk=1:nw=1 "$MOV" 2>/dev/null)
      dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$MOV" 2>/dev/null)
      if [[ "${frames:-x}" =~ ^[0-9]+$ ]] && (( frames > 0 )); then
        ok ".mov: ${frames} frames, ${dur:-?}s (W5: SCK->h264 append worked)"
      else
        no ".mov has 0 readable frames (W5: append failed — see the W6 diagnostic in stderr/bridge log; may need AVAssetWriterInputPixelBufferAdaptor)"
      fi
    else
      no ".mov missing ($MOV) — capture did not run or did not finishWriting()"
    fi

    [[ -f "$MP4" ]] && ok ".mp4 rendered" || no ".mp4 missing ($MP4)"
    [[ -f "$GIF" ]] && ok ".gif rendered" || no ".gif missing ($GIF)"

    # Transcript: proves the bridge was reached AND the model obeyed the
    # prologue (called rig_checkpoint + rig_turn_end).
    if [[ -f "$TRANSCRIPT" ]]; then
      te=$(grep -c '"tool":"rig_turn_end"' "$TRANSCRIPT" 2>/dev/null)
      cp=$(grep -c '"tool":"rig_checkpoint"' "$TRANSCRIPT" 2>/dev/null)
      last=$(tail -n1 "$TRANSCRIPT" 2>/dev/null | jq -r '.tool' 2>/dev/null)
      (( te >= 1 )) && ok "transcript: $te rig_turn_end (prologue delivered + obeyed)" \
        || no "transcript: NO rig_turn_end (prologue not delivered, or model ignored it)"
      (( cp >= 1 )) && ok "transcript: $cp rig_checkpoint" \
        || no "transcript: NO rig_checkpoint (the 'greeted' checkpoint never fired)"
      [[ "$last" == "rig_turn_end" ]] && ok "last call is rig_turn_end" \
        || no "last transcript call is '${last:-none}' (expected rig_turn_end)"
    else
      no "transcript missing ($TRANSCRIPT) — bridge not reached (check .mcpb install + active-session pointer)"
    fi

    echo
    if (( fail == 0 )); then
      echo "[gate] artifact checks PASSED — re-run record.sh 10x for the MVV bar"
    else
      echo "[gate] $fail check(s) FAILED — run: $0 diagnose $SESSION" >&2
    fi
    (( fail == 0 ))
    ;;

  diagnose)
    echo "== .mov (ffprobe) =="
    if [[ -f "$MOV" ]]; then
      ffprobe -v error -count_frames -select_streams v:0 \
        -show_entries "stream=codec_name,nb_read_frames,width,height:format=duration,size" \
        -of default=noprint_wrappers=1 "$MOV" 2>&1 | head -12
    else echo "(absent: $MOV)"; fi
    echo "== transcript tool sequence =="
    [[ -f "$TRANSCRIPT" ]] && jq -r '"\(.tool) -> \(.result|tostring)"' "$TRANSCRIPT" 2>/dev/null || echo "(absent)"
    echo "== prompt-submitted (did the driver submit?) =="
    ls -la "/tmp/${SESSION}.prompt-submitted" 2>&1 | tail -1
    echo "== gate-pending / turn-end sentinels =="
    ls -la "/tmp/${SESSION}".{gate-pending,turn-end,checkpoint} 2>/dev/null || echo "(none)"
    echo "== bridge per-server log (liveness, last 6) =="
    [[ -f "$BRIDGE_LOG" ]] && tail -6 "$BRIDGE_LOG" || echo "(no bridge log at $BRIDGE_LOG)"
    echo "== orphan calls (session-resolution failures) =="
    tail -3 /tmp/recording-rig.orphan-calls.jsonl 2>/dev/null || echo "(none)"
    ;;

  *)
    echo "usage: $0 {verify|diagnose} [session]" >&2
    exit 2
    ;;
esac
