# SPDX-License-Identifier: MIT
#
# lib/stage-manager.sh — macOS Stage Manager auto-toggle (rr-sm0). Sourced by
# bin/record.sh's desktop arm.
#
# WHY: macOS Stage Manager (Ventura+; com.apple.WindowManager GloballyEnabled,
# default-on for many) repositions/animates windows on focus changes. During a
# multi-surface desktop recording the Claude-Rig window gets swooshed/shrunk on the
# focus changes between surface switches, and ScreenCaptureKit — locked to the
# step-0 window — then captures a skewed window on black for the rest of the run.
# record.sh disables Stage Manager for the recording and restores it in teardown.
#
# The DECISION (is it on?) is a pure function so it is unit-testable from synthetic
# `defaults read` output — the lib/competing-claude.sh precedent. The live
# `defaults`/`killall` wrappers are manual-smoke (the consent-sweep precedent).

_SM_DOMAIN="com.apple.WindowManager"
_SM_KEY="GloballyEnabled"

# stage_manager_is_enabled_from <defaults-output>
# PURE predicate: rc 0 iff <defaults-output> (a `defaults read <domain> GloballyEnabled`
# result) is "1" after trimming surrounding whitespace; rc 1 otherwise ("0", empty
# when the key is absent / read failed, or anything unexpected).
stage_manager_is_enabled_from() {
  local v="${1//[[:space:]]/}"
  [[ "$v" == "1" ]]
}

# stage_manager_current — LIVE: print the current GloballyEnabled value ("1"/"0");
# empty when the key is absent or the read fails (Stage Manager never configured).
stage_manager_current() {
  defaults read "$_SM_DOMAIN" "$_SM_KEY" 2>/dev/null || true
}

# stage_manager_is_enabled — LIVE predicate: rc 0 iff Stage Manager is currently on.
stage_manager_is_enabled() {
  stage_manager_is_enabled_from "$(stage_manager_current)"
}

# stage_manager_set <true|false> — LIVE: write GloballyEnabled and restart
# WindowManager so the change takes effect immediately (no logout). killall is
# best-effort (a fresh login may have no WindowManager yet); the defaults write is
# the load-bearing part, so its rc is what we return.
stage_manager_set() {
  local on="$1"
  defaults write "$_SM_DOMAIN" "$_SM_KEY" -bool "$on" || return 1
  killall WindowManager 2>/dev/null || true
}
