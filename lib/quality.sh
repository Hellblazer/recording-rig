# SPDX-License-Identifier: MIT
#
# Soft-miss aggregation for the desktop backend (RDR-001 Phase 3 Step 2,
# rr-2pp.4.2). Sourced by bin/record.sh (writer) and bin/doctor.sh (reader);
# see lib/quality.test.mjs for the contract.
#
# A "soft miss" is the Desktop instruction-drift failure: the model produced
# output but skipped rig_turn_end, so record.sh's turn-end watch hit the
# pacing.turn_timeout_sec ceiling (sentinel_wait_idle return 2). record.sh then
# synthesizes a fallback rig_turn_end so the recording COMPLETES (GIF + warning)
# rather than hard-failing, and logs the run to quality.jsonl for trend
# analysis. Doctor warns when the soft-miss rate exceeds 20% over the last N
# desktop runs (RDR-001 Risk "instruction drift").
#
# CLI runs are NOT logged: the Stop hook fires turn-end deterministically, so a
# CLI soft miss is structurally impossible, and touching the CLI flow would
# break the byte-identical regression gate (rr-2pp.4.4, invariant #6).

# Location of the append-only quality log. RIG_QUALITY_LOG overrides (tests +
# diagnose share it), mirroring the RIG_TMP override convention.
quality_log_path() {
  echo "${RIG_QUALITY_LOG:-$HOME/Library/Application Support/recording-rig/quality.jsonl}"
}

# Append one already-serialized JSON record (a single line) to the quality log,
# creating the parent directory if needed. A single sub-PIPE_BUF append is
# atomic on a local FS, so no .partial+rename dance is required here.
quality_log_append() {
  local record="$1" path
  path="$(quality_log_path)"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$record" >> "$path"
}

# Append a fallback rig_turn_end to the bridge transcript. Mirrors the field
# order bridge/server.js:appendTranscript writes ({ts,tool,args,result,session})
# so the validator's "last call must be rig_turn_end" check passes; result
# carries synthesized:true so diagnose (rr-2pp.4.3) can distinguish it from a
# genuine model call. The contract note in T2 (bridge-sentinel-contract) is
# explicit: a synthesized turn_end MUST land in the transcript or the gate
# cursor (k = #rig_turn_end entries) under-counts.
quality_synthesize_turn_end() {
  local transcript="$1" session="$2" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  jq -nc --arg ts "$ts" --arg session "$session" \
    '{ts:$ts, tool:"rig_turn_end", args:{}, result:{ok:true, synthesized:true}, session:$session}' \
    >> "$transcript"
}

# Print "<pct> <count>": the integer soft-miss percentage and sample size over
# the last $n desktop runs in the quality log. "0 0" for a missing/empty log or
# no desktop rows. Non-desktop rows are excluded from the denominator.
#
# Malformed lines are tolerated per-line (try fromjson | objects), mirroring
# validate.mjs's per-line try/catch — the RDR tells operators to truncate/rotate
# this log manually, so a partial trailing line must NOT silently abort the slurp
# (a strict `jq -s` would, leaving the advisory permanently silenced).
quality_soft_miss_rate() {
  local f="$1" n="${2:-20}"
  [[ -f "$f" && -s "$f" ]] || { echo "0 0"; return 0; }
  jq -Rrs --argjson n "$n" '
    [ split("\n")[] | select(length > 0) | (try fromjson) | objects | select(.backend == "desktop") ] as $d
    | ($d[-$n:]) as $w
    | ($w | length) as $c
    | if $c == 0 then "0 0"
      else "\(([ $w[] | select(.soft_miss == true) ] | length) * 100 / $c | floor) \($c)"
      end
  ' "$f"
}
