# SPDX-License-Identifier: MIT
#
# lib/competing-claude.sh — rr-re6 competing-Claude.app detection (RDR-001
# post-close follow-up). Sourced by bin/record.sh (the desktop preflight guard)
# and lib/desktop-doctor.sh (an advisory check).
#
# WHY: macOS activates apps per BUNDLE. `open -n -a Claude` while ANOTHER
# Claude.app instance exists lets the old instance keep the activation, so the
# freshly-launched Claude-Rig instance stays backgrounded — its Chromium
# accessibility tree never materializes and the driver's armWait times out (the
# failure rr-re6 tracked; a manual window click was rescuing it). Confirmed by
# Test A: with zero competing Claude.app mains the driver foregrounds the Rig
# instance on its own and records hands-free. So record.sh refuses to launch
# while a competing instance is up.
#
# The detection is split out as a PURE function (no live `ps`) so it is
# unit-testable from synthetic process lines — the lib/trusted-folders.sh
# precedent. The call sites pipe live `ps -axo pid=,command=` into it.

# competing_claude_pids <rig_user_data_dir>
# Read `pid command...` lines on stdin (one process per line; the pid is the
# first whitespace-delimited field, the remainder is the full command). Emit, one
# pid per line, every Claude.app MAIN process (Electron --type= helpers excluded)
# whose --user-data-dir is NOT <rig_user_data_dir>. An ABSENT --user-data-dir is
# the default/primary profile and therefore competing. Matching is boundary-aware
# so a sibling dir like ".../Claude-Rig-other" is NOT mistaken for the Rig dir.
# No output (rc 0) when nothing competes.
competing_claude_pids() {
  local rigdir="$1" pid rest
  # `|| [[ -n "${pid:-}" ]]` processes a final line that lacks a trailing newline;
  # on true EOF read clears pid to empty, so there is no stale double-processing.
  while read -r pid rest || [[ -n "${pid:-}" ]]; do
    [[ -n "$pid" && -n "$rest" ]] || continue
    # Claude.app processes only — match the marker at argv[0] (the executable),
    # NOT anywhere in the command line, so a grep/editor/script that merely carries
    # the path as an argument does not false-positive. argv[0] is the first
    # whitespace-delimited token; the Claude executable path contains no spaces.
    [[ "${rest%% *}" == *"Claude.app/Contents/MacOS/Claude" ]] || continue
    # Mains only — renderer/GPU/utility children carry --type=; only a main window
    # competes for bundle activation.
    [[ "$rest" == *"--type="* ]] && continue
    # The Rig instance itself is not competing. Boundary-aware: the udd value is
    # either at end-of-cmdline or followed by a space (next arg), so "/rig" does
    # not match "/rig-other".
    case "$rest" in
      *"--user-data-dir=$rigdir") continue ;;
      *"--user-data-dir=$rigdir "*) continue ;;
    esac
    printf '%s\n' "$pid"
  done
}
