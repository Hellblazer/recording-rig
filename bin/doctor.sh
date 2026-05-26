#!/usr/bin/env bash
# Verify recording-rig prereqs. Exit 0 on all pass, non-zero on any fail.
# Used by the `doctor` skill and the /recording-rig:doctor slash command.
set -u

fail=0
ok() { printf "  ✓  %s\n" "$1"; }
bad() { printf "  ✗  %s\n" "$1" >&2; fail=$((fail+1)); }
warn() { printf "  ⚠  %s\n" "$1" >&2; }   # advisory: does NOT fail doctor
hint() { printf "     → %s\n" "$1" >&2; }

# Desktop-backend checks + opt-in subcommands live in the sourced seam
# (lib/desktop-doctor.sh, rr-2pp.6.1). It defines functions only; §7 below runs
# the checks, the dispatch block here routes the subcommands. Guard the source
# (no set -e here): a missing lib would otherwise surface as an opaque
# "command not found" on the first desktop_* call.
_DOCTOR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/desktop-doctor.sh"
if [[ ! -f "$_DOCTOR_LIB" ]]; then
  echo "doctor: lib/desktop-doctor.sh not found at $_DOCTOR_LIB — recording-rig install incomplete" >&2
  exit 2
fi
# shellcheck disable=SC1091
source "$_DOCTOR_LIB"

# Subcommand mode: `doctor --install-bridge` (etc.) dispatches an opt-in desktop
# action instead of running the standard checks. macOS-only — a CLI user on
# another OS gets a clear refusal rather than a confusing unknown-flag error.
if (( $# > 0 )); then
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "doctor: '$1' is a macOS-only desktop subcommand (the desktop backend requires macOS)" >&2
    exit 2
  fi
  _desktop_doctor_dispatch "$@"
  exit $?
fi

echo "[doctor] checking prereqs..."

# 1. Binaries on PATH
for b in tmux jq asciinema agg claude node; do
  if command -v "$b" >/dev/null 2>&1; then
    ok "$b on PATH ($(command -v "$b"))"
  else
    bad "$b MISSING"
    case "$b" in
      tmux|jq|asciinema|agg|node) hint "install: brew install $b" ;;
      claude) hint "install: see https://docs.claude.com/en/docs/claude-code" ;;
    esac
  fi
done

# 2. Bash version
if (( BASH_VERSINFO[0] >= 4 )); then
  ok "bash version ${BASH_VERSION%%(*}"
else
  bad "bash ${BASH_VERSION} is too old (need 4+)"
  hint "install: brew install bash, then ensure /opt/homebrew/bin is in PATH before /bin"
fi

# 3. asciinema v2 format support
if command -v asciinema >/dev/null 2>&1; then
  if asciinema rec --help 2>&1 | grep -q "asciicast-v2"; then
    ok "asciinema supports --output-format asciicast-v2"
  else
    bad "asciinema does not advertise asciicast-v2 — validator parses v2 only"
    hint "upgrade asciinema or downgrade to a v2-emitting build"
  fi
fi

# 4. claude reachable
if command -v claude >/dev/null 2>&1; then
  if claude --version >/dev/null 2>&1; then
    ok "claude --version succeeds ($(claude --version 2>&1 | head -1))"
  else
    bad "claude --version failed — not logged in?"
    hint "log in interactively first: claude"
  fi
fi

# 5. tmux can spawn detached on the rig's dedicated socket
RIG_TMUX_SOCKET="${RIG_TMUX_SOCKET:-recording-rig}"
if command -v tmux >/dev/null 2>&1; then
  s="rig-doctor-$$"
  if tmux -L "$RIG_TMUX_SOCKET" new-session -d -s "$s" 'sleep 1' 2>/dev/null; then
    ok "tmux new-session on socket '$RIG_TMUX_SOCKET' works"
    tmux -L "$RIG_TMUX_SOCKET" kill-session -t "$s" 2>/dev/null || true
  else
    bad "tmux new-session failed on socket '$RIG_TMUX_SOCKET'"
    hint "check ~/.tmux.conf for syntax errors; try: tmux -L $RIG_TMUX_SOCKET -f /dev/null new-session -d -s test"
  fi
fi

# 6. agg can render a trivial cast
if command -v agg >/dev/null 2>&1; then
  tmp_cast="/tmp/rig-doctor-$$.cast"
  tmp_gif="/tmp/rig-doctor-$$.gif"
  printf '{"version":2,"width":80,"height":24}\n[0.1,"o","hello\\n"]\n' > "$tmp_cast"
  if agg --idle-time-limit 1 "$tmp_cast" "$tmp_gif" >/dev/null 2>&1; then
    ok "agg renders a trivial cast"
  else
    bad "agg failed on a trivial cast"
    hint "check agg version: agg --version"
  fi
  rm -f "$tmp_cast" "$tmp_gif"
fi

# 7. Desktop backend (macOS) — opt-in via spec backend:"desktop". These WARN
#    rather than fail: a CLI-backend user does not need them. (RDR-001 Phase 2.)
#    The check bodies live in lib/desktop-doctor.sh (sourced above, rr-2pp.6.1).
if [[ "$(uname)" == "Darwin" ]]; then
  desktop_doctor_checks
fi

echo
if (( fail == 0 )); then
  echo "[doctor] all checks passed."
  exit 0
else
  echo "[doctor] $fail check(s) failed." >&2
  exit 1
fi
