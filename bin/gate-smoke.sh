#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Manual Phase 1 gate helper for recording-rig-bridge (rr-2pp.2.4).
#
# RUN THIS ON THE macOS HOST. The bridge runs as a child of Claude.app and
# writes /tmp/${SESSION}.* on this host. Do NOT run the verification from inside
# Claude's analysis sandbox (Linux) — it cannot see host /tmp, and its `stat`
# uses GNU flags (-c) while the host needs BSD flags (-f).
#
# Usage:
#   bin/gate-smoke.sh seed     [session]   # wipe stale state + seed pointer & rig-config
#   bin/gate-smoke.sh verify   [session]   # read back sentinels + transcript (host)
#   bin/gate-smoke.sh diagnose [session]   # locate where the bridge actually writes
#
# Default session: gate-smoke.
set -euo pipefail

SESSION="${2:-gate-smoke}"
POINTER="/tmp/recording-rig.active-session"
ORPHAN="/tmp/recording-rig.orphan-calls.jsonl"
RIGCONFIG="/tmp/${SESSION}.rig-config.json"
TRANSCRIPT="/tmp/${SESSION}.bridge-transcript.jsonl"

case "${1:-}" in
  seed)
    # The bridge has no memory between calls; it rebuilds its command index
    #   k = (number of rig_turn_end entries in the transcript)
    # so a stale transcript from a prior attempt keeps k>=1 and a for_command-
    # pinned gate never matches. record.sh wipes /tmp/${SESSION}.* via
    # sentinel_clear_all() before every real session — the manual gate must do
    # the same before EVERY attempt. Wipe first (NOT the global pointer).
    rm -f /tmp/"${SESSION}".*
    printf '%s' "${SESSION}" > "${POINTER}"   # single-line id, no trailing newline
    # for_command-less gate: matches regardless of k. Correct for a single-
    # command smoke test (the command-boundary path is covered by unit tests).
    printf '%s' "{\"session\":\"${SESSION}\",\"gates\":[{\"answer_index\":1}]}" > "${RIGCONFIG}"
    echo "seeded session=${SESSION}"
    echo "  pointer    ${POINTER} -> $(cat "${POINTER}")"
    echo "  rig-config ${RIGCONFIG} -> $(cat "${RIGCONFIG}")"
    echo
    echo "Next: in Claude-Rig Chat call rig_ask with options [\"no\",\"yes\"]"
    echo "Expect: {answer_index:1, answer_value:\"yes\"}. Then run: $0 verify ${SESSION}"
    ;;

  verify)
    echo "== pointer (${POINTER}) =="
    cat "${POINTER}" 2>/dev/null && echo || echo "(absent)"
    echo "== sentinels (size + content) =="
    for f in turn-end checkpoint answer gate-pending; do
      p="/tmp/${SESSION}.${f}"
      if [[ -e "${p}" ]]; then
        printf '%-14s %4sb  %s\n' "${f}" "$(stat -f %z "${p}")" "$(cat "${p}")"
      else
        printf '%-14s (absent)\n' "${f}"
      fi
    done
    echo "== transcript (${TRANSCRIPT}) =="
    cat "${TRANSCRIPT}" 2>/dev/null || echo "(absent)"
    echo "== orphan log (${ORPHAN}) =="
    cat "${ORPHAN}" 2>/dev/null || echo "(none)"
    ;;

  diagnose)
    echo "== pointer (${POINTER}) =="
    cat "${POINTER}" 2>/dev/null && echo || echo "(absent — seed first)"
    echo "== does the bridge write to /tmp? =="
    if ls /tmp/"${SESSION}".* >/dev/null 2>&1; then
      echo "YES — bridge writes to host /tmp:"
      ls -la /tmp/"${SESSION}".*
    else
      echo "NO ${SESSION}.* in /tmp. The bridge may write to a sandbox-redirected"
      echo "tmp. Searching ~/Library/Containers ..."
      find "${HOME}/Library/Containers" -maxdepth 4 \
        \( -name "${SESSION}.*" -o -name "recording-rig.active-session" \) 2>/dev/null | head || true
      echo "(any match above => the bridge's /tmp is there; set RIG_TMP to match,"
      echo " or check ~/Library/Logs/Claude/mcp-server-Recording\\ Rig\\ Bridge.log)"
    fi
    ;;

  *)
    echo "usage: $0 {seed|verify|diagnose} [session]" >&2
    exit 2
    ;;
esac
