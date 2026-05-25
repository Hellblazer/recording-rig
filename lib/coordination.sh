# SPDX-License-Identifier: MIT
#
# CoordinationProvider seam for the desktop backend (RDR-001 Phase 4 Step 2,
# rr-2pp.5.2). Sourced by bin/record.sh; see lib/coordination.test.mjs for the
# contract. The turn-end *watch* stays in record.sh/shell (RDR L169) — this file
# only chooses HOW to detect turn-end per surface and exposes that behind one
# dispatch so record.sh's desktop arm calls the same function regardless.
#
# Providers (RDR-001 §Technical Design, amended 2026-05-25):
#   mcp-bridge            — Chat + Code (A1 verified). waitTurnEnd is the EXISTING
#                           sentinel_wait_idle watch, unchanged. Supports rig.ask
#                           gates. The CLI backend never reaches this file.
#   agent-transcript-tail — CoWork primary + Code recovery. waitTurnEnd tails the
#                           per-session Claude-Agent-SDK transcript audit.jsonl
#                           for an explicit {"type":"result"} turn-end line. No
#                           rig.ask reaches the VM, so gates are unsupported.
#                           (Supersedes the originally-planned coworkd-log-tail,
#                           which the rr-2pp.5.2 live probe proved carries no turn
#                           signal, and file-mtime-watch, which it dominates.)
#
# Return-code contract for coordination_wait_turn_end (mirrors sentinel_wait_idle
# so record.sh's IDLE_RC soft-miss branch is unchanged):
#   0 = turn-end observed
#   1 = session ceiling exceeded
#   2 = turn_timeout (no progress within pacing.turn_timeout_sec) -> SOFT miss
#   3 = agent-transcript-tail only: no transcript ever appeared -> HARD miss
#       (record.sh maps any rc != {0,2} to "did not settle cleanly", SOFT_MISS=0)

# sentinel_wait_idle lives in sentinels.sh; record.sh sources it first, but make
# this file self-contained for tests / standalone sourcing.
if ! declare -f sentinel_wait_idle >/dev/null 2>&1; then
  _coord_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/sentinels.sh
  source "$_coord_here/sentinels.sh"
fi

# Resolve the provider for a surface. An explicit, non-"auto" coordination value
# from the spec wins; otherwise the RDR-locked per-surface default map applies.
# (The richer doctor-probe-cache resolution is Phase 5, rr-2pp.6.1.)
coordination_provider_for_surface() {
  local surface="$1" explicit="${2:-auto}"
  if [[ -n "$explicit" && "$explicit" != "auto" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  case "$surface" in
    chat | code) printf 'mcp-bridge' ;;
    cowork) printf 'agent-transcript-tail' ;;
    *)
      echo "coordination: unknown surface '$surface'" >&2
      return 1
      ;;
  esac
}

# Capability query consumed by the spec preflight (rr-2pp.5.4): does the provider
# carry rig.ask gates? Only mcp-bridge does. rc 0 = yes, 1 = no, 2 = unknown.
coordination_supports_gates() {
  case "$1" in
    mcp-bridge) return 0 ;;
    agent-transcript-tail) return 1 ;;
    *)
      echo "coordination: unknown provider '$1'" >&2
      return 2
      ;;
  esac
}

# Pre-paste setup. For agent-transcript-tail this prints a BASELINE epoch: only
# an audit.jsonl modified at/after submit is a candidate, so a completed prior
# run's stale {"type":"result"} cannot be mistaken for this turn's end. Callers
# capture the value and pass it to coordination_wait_turn_end. mcp-bridge needs
# none (record.sh already wrote the active-session pointer + installed bridge).
coordination_ready() {
  case "$1" in
    agent-transcript-tail) date +%s ;;
    mcp-bridge) : ;;
    *)
      echo "coordination: unknown provider '$1'" >&2
      return 1
      ;;
  esac
}

# coordination_wait_turn_end <provider> <idle> <turn_timeout> <session_max> [root] [baseline]
# rc per the contract above. `idle` is the turn-end mtime quiet window (mcp-bridge
# only; agent-transcript-tail ends on the explicit result line). `root` is the rig
# profile's local-agent-mode-sessions dir; `baseline` is from coordination_ready.
coordination_wait_turn_end() {
  local provider="$1"
  shift
  case "$provider" in
    mcp-bridge)
      # idle turn_timeout session_max -> the existing watch, byte-identical.
      sentinel_wait_idle "${1:-8}" "${2:-120}" "${3:-1800}"
      ;;
    agent-transcript-tail)
      # idle ($1) is unused (result is explicit); root=$4, baseline=$5.
      _coord_transcript_wait_turn_end "${4:-}" "${2:-120}" "${3:-1800}" "${5:-0}"
      ;;
    *)
      echo "coordination: unknown provider '$provider'" >&2
      return 1
      ;;
  esac
}

# Teardown hook. Both providers poll (no background tail), so they hold no
# resources; this is a no-op kept for contract completeness + future use.
coordination_teardown() {
  case "$1" in
    mcp-bridge | agent-transcript-tail) : ;;
    *)
      echo "coordination: unknown provider '$1'" >&2
      return 1
      ;;
  esac
}

# --- agent-transcript-tail internals ---

# BSD then GNU stat, mirroring sentinels.sh.
_coord_audit_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# Newest <root>/**/audit.jsonl whose mtime >= baseline. Prints the path; returns
# 1 when none qualifies (so the caller keeps polling — the session dir may not be
# created yet right after submit).
_coord_newest_audit() {
  local root="$1" baseline="${2:-0}" best="" best_m=0 f m
  [[ -n "$root" && -d "$root" ]] || return 1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    m="$(_coord_audit_mtime "$f")" || continue
    [[ "$m" =~ ^[0-9]+$ ]] || continue
    (( m >= baseline )) || continue
    if (( m >= best_m )); then
      best_m=$m
      best="$f"
    fi
  done < <(find "$root" -type f -name audit.jsonl 2>/dev/null)
  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}

# Tolerant NDJSON: true iff audit.jsonl has at least one {"type":"result"} line.
# Per-line (try fromjson | objects) so a partial trailing write never aborts the
# slurp (the NDJSON-tolerance discipline from lib/quality.sh).
_coord_audit_has_result() {
  local f="$1" n
  [[ -s "$f" ]] || return 1
  n="$(jq -Rrs '[ split("\n")[] | select(length > 0) | (try fromjson) | objects | select(.type == "result") ] | length' "$f" 2>/dev/null || echo 0)"
  [[ "${n:-0}" =~ ^[0-9]+$ ]] || n=0
  (( n > 0 ))
}

# Poll the newest post-baseline audit.jsonl until it carries a {"type":"result"}
# line. Return codes:
#   0 = result seen (turn-end)
#   1 = session ceiling exceeded
#   2 = SOFT miss: the transcript appeared and grew but produced no result line
#       within turn_timeout (the model worked but skipped/never reached a result)
#   3 = HARD miss: no qualifying audit.jsonl ever appeared within turn_timeout
#       (the model never started — prompt not received, session failed to spawn)
# record.sh treats any rc != {0,2} as "did not settle cleanly" (SOFT_MISS=0), so
# rc 3 keeps a hard miss out of the soft-miss telemetry without special-casing.
#
# "Progress" = the transcript growing (new bytes); the first appearance of the
# transcript also resets the clock, so the pre-submit latency (driver fork + AX
# inject + first-token roundtrip) before audit.jsonl exists does not burn the
# model's turn_timeout budget.
_coord_transcript_wait_turn_end() {
  local root="$1" turn_timeout="${2:-120}" session_max="${3:-1800}" baseline="${4:-0}"
  local elapsed=0 since_progress=0 last_size=-1 audit size seen=0
  while :; do
    audit="$(_coord_newest_audit "$root" "$baseline")" || audit=""
    if [[ -n "$audit" && -f "$audit" ]]; then
      _coord_audit_has_result "$audit" && return 0
      if (( ! seen )); then
        # First appearance: the model has started. Give it a fresh turn_timeout
        # budget rather than charging it for the pre-submit latency.
        seen=1
        since_progress=0
      fi
      size="$(wc -c <"$audit" 2>/dev/null || echo 0)"
      if (( size > last_size )); then
        last_size=$size
        since_progress=0
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    since_progress=$((since_progress + 1))
    if (( since_progress >= turn_timeout )); then
      if (( seen )); then
        echo "coordination(agent-transcript-tail): transcript stalled ${turn_timeout}s with no {type:result}" >&2
        return 2
      fi
      echo "coordination(agent-transcript-tail): no audit.jsonl appeared within ${turn_timeout}s (hard miss)" >&2
      return 3
    fi
    if (( elapsed >= session_max )); then
      echo "coordination(agent-transcript-tail): session ceiling ${session_max}s exceeded" >&2
      return 1
    fi
  done
}
