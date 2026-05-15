#!/usr/bin/env bash
# Meta-test: run the rig inside an "isolated sandbox" claude installation.
# The sandbox has its own HOME but with key files BIND-symlinked to the
# user's real ~/.claude so OAuth / keychain auth works, while the user's
# ambient plugins/skills/agents/CLAUDE.md are sandboxed away.
#
# Outer recording: invokes /recording-rig:record on inner-spec.json from
# inside a sandboxed claude session. Validator asserts the inner rig's
# log lines appeared in the outer cast — proving the rig works as a
# plugin under HOME-isolation AND survives nested tmux.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SANDBOX=$(mktemp -d /tmp/rig-sandbox-XXXXXX)
echo "[meta] sandbox HOME = $SANDBOX"

# Symlink every direct dotfile and every non-overridden ~/.claude/ entry.
# Then layer ~/.claude/plugins → empty dir so only --plugin-dir loads.
shopt -s dotglob nullglob
for f in "$HOME"/*; do
  name=$(basename "$f")
  case "$name" in
    .claude) ;;  # special-case below
    *) ln -s "$f" "$SANDBOX/$name" ;;
  esac
done

mkdir -p "$SANDBOX/.claude"
for entry in "$HOME"/.claude/*; do
  name=$(basename "$entry")
  case "$name" in
    plugins|skills|agents|CLAUDE.md)
      # Sandbox: empty directory (still navigable) instead of symlink
      [[ "$name" != "CLAUDE.md" ]] && mkdir -p "$SANDBOX/.claude/$name"
      ;;
    settings.json|settings.local.json)
      # Sandbox: write a fresh empty config so user-level hooks don't fire
      # in the recorded session (e.g. broken codex-hook entries).
      echo '{}' > "$SANDBOX/.claude/$name"
      ;;
    *)
      ln -s "$entry" "$SANDBOX/.claude/$name"
      ;;
  esac
done
shopt -u dotglob nullglob

# Clean any prior meta-rig artifacts.
tmux -L recording-rig kill-session -t meta-rig 2>/dev/null || true
tmux -L recording-rig kill-session -t meta-rig-warmup 2>/dev/null || true
tmux -L recording-rig kill-session -t inner-spec 2>/dev/null || true
tmux -L recording-rig kill-session -t inner-spec-warmup 2>/dev/null || true
rm -f /tmp/meta-rig.* /tmp/inner-spec.*

cleanup() {
  local rc=$?
  echo "[meta] cleanup: removing sandbox $SANDBOX"
  rm -rf "$SANDBOX"
  return $rc
}
trap cleanup EXIT

HOME="$SANDBOX" "$HERE/bin/record.sh" "$HERE/test-runs/meta-rig.json"
OUTER_RC=$?
echo "[meta] outer rig exited with rc=$OUTER_RC"

# Wait for the detached inner rig to finish — agent kicked it off with
# 'nohup ... &', so it runs after the outer recording terminates. Poll for
# the inner .gif (last artifact agg produces). Cap at 180s.
echo "[meta] waiting for inner rig to produce /tmp/inner-spec.gif ..."
for ((i=0; i<60; i++)); do
  if [[ -e /tmp/inner-spec.gif ]] && [[ $(stat -f %z /tmp/inner-spec.gif 2>/dev/null || stat -c %s /tmp/inner-spec.gif) -gt 0 ]]; then
    echo "[meta] inner-spec.gif appeared after ${i}*3s"
    break
  fi
  sleep 3
done

echo
echo "=== inner-spec artifacts ==="
ls -la /tmp/inner-spec.* 2>&1 | head -10
echo
echo "=== inner rig stdout (head/tail) ==="
[[ -e /tmp/inner-spec.out ]] && {
  echo "--- head ---"
  head -8 /tmp/inner-spec.out
  echo "--- tail ---"
  tail -3 /tmp/inner-spec.out
}

# Final pass criterion: inner rig produced a valid GIF
if [[ -e /tmp/inner-spec.gif ]] && (( $(stat -f %z /tmp/inner-spec.gif 2>/dev/null || stat -c %s /tmp/inner-spec.gif) > 10000 )); then
  echo "[meta] PASS: outer rig recorded the spawn AND inner rig completed standalone"
  exit 0
else
  echo "[meta] FAIL: inner rig did not produce a GIF" >&2
  exit 1
fi
