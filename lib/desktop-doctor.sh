# SPDX-License-Identifier: MIT
#
# lib/desktop-doctor.sh — Desktop-backend (macOS) doctor checks + subcommand
# dispatch (RDR-001 Phase 5 Step 1, rr-2pp.6.1). Sourced by bin/doctor.sh.
#
# WHY A SEAM: the desktop preflight grew past the inline section-7 block in
# bin/doctor.sh — it now reads live TCC grants (via bin/perms-check), the bridge
# enable flag, the isolated profile, and the probe caches, and it dispatches the
# opt-in mutating subcommands (--install-bridge etc.). Pulling it into a sourced
# lib keeps doctor.sh readable and lets lib/desktop-doctor.test.mjs exercise each
# check + the router in isolation (the lib/trusted-folders.sh precedent).
#
# CONTRACT WITH bin/doctor.sh: this file only DEFINES functions at source time;
# it calls ok()/warn()/hint() — supplied by the caller — at CHECK time. Every
# Desktop check is advisory (warn, never bad): a CLI-backend user needs none of
# them, so they must never fail `doctor`. The mutating subcommands are opt-in
# and land in rr-5kf..rr-3zb; here they are stubs the router can already route.
#
# All paths are env-overridable so the tests can point them at temp fixtures and
# a stub perms-check; the live defaults match bin/record.sh's desktop arm
# ($HOME/Library/Application Support/Claude-Rig, record.sh:287) and the bridge
# enable-flag location (RDR-001 invariant: plaintext {"isEnabled":true}).

_DESKTOP_DOCTOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RIG_ROOT="$(cd "$_DESKTOP_DOCTOR_LIB_DIR/.." && pwd)"

# Soft-miss trend reader (preserved from the old section-7 block — do not drop:
# doctor's instruction-drift advisory depends on it). Sourced once here so the
# seam is self-contained.
# shellcheck disable=SC1091
source "$_DESKTOP_DOCTOR_LIB_DIR/quality.sh"
# rr-re6 competing-Claude.app detection (the decision fn behind record.sh's
# desktop guard) — reused by the advisory check below.
# shellcheck disable=SC1091
source "$_DESKTOP_DOCTOR_LIB_DIR/competing-claude.sh"

# --- resolvable paths (env overrides win; live defaults below) ---
: "${CLAUDE_RIG_DIR:=$HOME/Library/Application Support/Claude-Rig}"
: "${RIG_CLAUDE_APP:=/Applications/Claude.app}"
: "${RIG_PERMS_CHECK:=$_RIG_ROOT/bin/perms-check}"
# The bridge enable flag: plaintext {"isEnabled":true} in the profile. Installed-
# but-disabled is indistinguishable at runtime from the lazy-load miss (rr-yfj),
# so doctor checks BOTH presence and the flag.
: "${RIG_BRIDGE_SETTINGS:=$CLAUDE_RIG_DIR/Claude Extensions Settings/local.mcpb.hellblazer.recording-rig-bridge.json}"
# --install-bridge inputs (rr-5kf). The .mcpb is a plain zip; Claude.app installs
# it UNPACKED under Claude Extensions/<ext-id>/ (verified live: unzip == the
# installed dir). The <ext-id> encoding (local.mcpb.<author>.<name>) is
# Claude.app-internal — re-verify on a Claude.app upgrade (the rr-yfj-class risk).
: "${RIG_BRIDGE_MCPB:=$_RIG_ROOT/bridge/recording-rig-bridge.mcpb}"
: "${RIG_BRIDGE_EXT_ID:=local.mcpb.hellblazer.recording-rig-bridge}"
: "${RIG_BRIDGE_EXT_DIR:=$CLAUDE_RIG_DIR/Claude Extensions/$RIG_BRIDGE_EXT_ID}"
# --install-profile / --seed-from-primary inputs (rr-7u0). The web sessionKey
# (A7, ~28d TTL) lives in the Chromium profile, NOT the electron-store oauth key
# — so the seed copies the session-bearing artifacts (RDR-001 §A7: Cookies, Local
# Storage, IndexedDB) and NEVER config.json (that would clobber Rig's trusted
# folders + dxt allowlist). Newline-separated, profile-relative, overridable;
# only artifacts that exist in the primary are copied. Confirm the set on a live
# --seed-from-primary (Claude.app-internal layout, the rr-yfj-class risk).
: "${RIG_PRIMARY_PROFILE:=$HOME/Library/Application Support/Claude}"
: "${RIG_SEED_AUTH_PATHS:=Cookies
Cookies-journal
Local Storage
Session Storage
IndexedDB}"
# Probe caches written by `doctor --probe-surfaces` (rr-3zb); their freshness is
# how doctor knows the AX selectors + per-surface MCP probe were last validated
# against the live app. Absent until --probe-surfaces has run in this profile.
: "${RIG_SELECTOR_CACHE:=$CLAUDE_RIG_DIR/.recording-rig/ax-selectors.probe.json}"
: "${RIG_PROBE_CACHE:=$CLAUDE_RIG_DIR/.recording-rig/surface-probe.json}"
# --probe-surfaces uses the read-only AX dumper (rr-3zb); overridable for tests.
: "${RIG_AXDUMP:=$_RIG_ROOT/bin/ax-dump}"

# Exact System Settings panes (asserted by the tests; the operator pastes these).
RIG_PANE_ACCESSIBILITY="System Settings > Privacy & Security > Accessibility"
RIG_PANE_SCREEN_RECORDING="System Settings > Privacy & Security > Screen Recording"

# _desktop_cache_fresh <file> <max_age_days>
# 0 iff <file> exists and was modified within <max_age_days>; 1 otherwise
# (absent, unreadable mtime, or stale). macOS `stat -f %m` (this path is Darwin).
_desktop_cache_fresh() {
  local f="$1" days="$2" now mtime
  [[ -e "$f" ]] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$f" 2>/dev/null) || return 1
  (( (now - mtime) / 86400 <= days ))
}

# --- individual checks (each advisory; call ok/warn/hint from the caller) ---

_desktop_check_claude_app() {
  if [[ -d "$RIG_CLAUDE_APP" ]]; then
    ok "Claude.app present ($RIG_CLAUDE_APP)"
  else
    warn "Claude.app not found at $RIG_CLAUDE_APP — the desktop backend launches it via open -a"
    hint "install Claude desktop from https://claude.ai/download"
  fi
}

# Read the controlling process's TCC grants via bin/perms-check (rr-nke) and
# advise per permission. perms-check reports ITS OWN grants as a proxy for the
# desktop-driver runtime; mismatch is possible, hence advisory (see the helper's
# TCC-attributes-to-parent caveat).
_desktop_check_perms() {
  if [[ ! -x "$RIG_PERMS_CHECK" ]]; then
    warn "perms-check not built — cannot verify Accessibility / Screen Recording grants"
    hint "build: bin/build-perms-check.sh"
    return 0
  fi
  local json acc scr
  json="$("$RIG_PERMS_CHECK" 2>/dev/null)"
  acc="$(jq -r '.accessibility // empty' <<<"$json" 2>/dev/null)"
  scr="$(jq -r '.screenRecording // empty' <<<"$json" 2>/dev/null)"
  if [[ "$acc" == "true" ]]; then
    ok "Accessibility permission granted"
  else
    warn "Accessibility permission NOT granted — the desktop driver cannot drive the AX tree"
    hint "grant in $RIG_PANE_ACCESSIBILITY"
  fi
  if [[ "$scr" == "true" ]]; then
    ok "Screen Recording permission granted"
  else
    warn "Screen Recording permission NOT granted — the desktop capture will be blank"
    hint "grant in $RIG_PANE_SCREEN_RECORDING"
  fi
}

_desktop_check_profile() {
  if [[ -d "$CLAUDE_RIG_DIR" ]]; then
    ok "Claude-Rig profile exists ($CLAUDE_RIG_DIR)"
  else
    warn "Claude-Rig profile absent — no isolated desktop profile has been created yet"
    hint "create + log in once: doctor --install-profile"
  fi
}

_desktop_check_bridge() {
  if [[ ! -f "$RIG_BRIDGE_SETTINGS" ]]; then
    warn "recording-rig-bridge not installed in the Claude-Rig profile"
    hint "install: doctor --install-bridge"
    return 0
  fi
  local enabled
  enabled="$(jq -r '.isEnabled // false' "$RIG_BRIDGE_SETTINGS" 2>/dev/null)"
  if [[ "$enabled" == "true" ]]; then
    ok "recording-rig-bridge installed and enabled"
  else
    warn "recording-rig-bridge installed but DISABLED (isEnabled != true) — no rig_* tools will load (looks identical to the rr-yfj lazy-load miss)"
    hint "enable in Claude.app Settings > Extensions, or re-run: doctor --install-bridge"
  fi
}

_desktop_check_caches() {
  if _desktop_cache_fresh "$RIG_SELECTOR_CACHE" 30; then
    ok "AX-selector probe cache fresh (<30d)"
  elif [[ -e "$RIG_SELECTOR_CACHE" ]]; then
    warn "AX-selector probe cache is stale (>30d) — selectors may have drifted on a Claude.app upgrade"
    hint "re-validate: doctor --probe-surfaces"
  else
    warn "AX-selector probe cache absent — selectors have never been live-validated in this profile"
    hint "generate: doctor --probe-surfaces"
  fi
  if _desktop_cache_fresh "$RIG_PROBE_CACHE" 30; then
    ok "surface MCP-probe cache fresh (<30d)"
  elif [[ -e "$RIG_PROBE_CACHE" ]]; then
    warn "surface MCP-probe cache is stale (>30d)"
    hint "re-validate: doctor --probe-surfaces"
  else
    warn "surface MCP-probe cache absent — surfaces have never been probed in this profile"
    hint "generate: doctor --probe-surfaces"
  fi
}

# Competing-instance advisory (rr-re6): a NON-Rig Claude.app instance running at
# record time steals macOS foreground from the Rig instance record.sh launches, so
# its Chromium accessibility tree never materializes and the desktop driver times
# out. record.sh ENFORCES this (refuses); doctor surfaces it so the operator can
# quit the other instance ahead of time. Reuses competing_claude_pids over live ps.
_desktop_check_competing_claude() {
  local competing
  competing="$(ps -axo pid=,command= | competing_claude_pids "$CLAUDE_RIG_DIR" | paste -sd' ' -)"
  if [[ -z "$competing" ]]; then
    ok "no competing Claude.app instance running"
  else
    warn "a competing Claude.app instance is running (pid(s): $competing) — it steals foreground from the Claude-Rig instance, blocking hands-free desktop recording (record.sh refuses)"
    hint "quit your other Claude.app (⌘Q) before recording, or set RIG_ALLOW_COMPETING_CLAUDE=1 to override"
  fi
}

# desktop_doctor_checks — run every Desktop advisory check. Sections relocated
# from bin/doctor.sh §7 (render deps + build artifacts + soft-miss trend) plus
# the new live checks (Claude.app, TCC perms, profile, bridge, probe caches).
# Returns 0 always: these are advisories, never failures.
desktop_doctor_checks() {
  # Render dependencies (bin/render-webm.sh .mov -> .mp4/.gif).
  if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg on PATH ($(command -v ffmpeg)) — desktop render"
  else
    warn "ffmpeg MISSING — required for the desktop backend render (bin/render-webm.sh)"
    hint "install: brew install ffmpeg"
  fi
  if command -v gifski >/dev/null 2>&1; then
    ok "gifski on PATH ($(command -v gifski)) — higher-quality desktop GIFs"
  else
    warn "gifski not found — OPTIONAL; render-webm falls back to ffmpeg palettegen"
    hint "install (recommended for GIF quality): brew install gifski"
  fi
  # Toolchain to build the Swift driver + helpers.
  if command -v swiftc >/dev/null 2>&1; then
    ok "swiftc on PATH ($(command -v swiftc)) — desktop driver build"
  else
    warn "swiftc MISSING — required to build bin/desktop-driver"
    hint "install: xcode-select --install"
  fi

  _desktop_check_claude_app
  _desktop_check_perms

  # Built/present artifacts the desktop record.sh path requires (surface them
  # here so a passing doctor doesn't hide a later record.sh preflight failure).
  if [[ -x "$_RIG_ROOT/bin/desktop-driver" ]]; then
    ok "bin/desktop-driver built"
  else
    warn "bin/desktop-driver not built — desktop recordings will fail preflight"
    hint "build: bin/build-desktop-driver.sh"
  fi
  [[ -f "$_RIG_ROOT/bin/desktop-ax-selectors.json" ]] \
    && ok "bin/desktop-ax-selectors.json present" \
    || warn "bin/desktop-ax-selectors.json missing — required by the desktop driver"
  [[ -x "$_RIG_ROOT/bin/render-webm.sh" ]] \
    && ok "bin/render-webm.sh present" \
    || warn "bin/render-webm.sh missing — required for the desktop render"

  _desktop_check_profile
  _desktop_check_bridge
  _desktop_check_competing_claude
  _desktop_check_caches

  # Soft-miss trend (RDR-001 Phase 3 Step 2): warn when the Desktop model skips
  # rig.turn_end too often (instruction drift). Advisory; needs jq; silent on
  # <3 samples. Uses quality.sh (sourced at the top of this lib).
  if command -v jq >/dev/null 2>&1; then
    local qlog smr_pct smr_n
    qlog="$(quality_log_path)"
    read -r smr_pct smr_n < <(quality_soft_miss_rate "$qlog" 20)
    if (( smr_n >= 3 )); then
      if (( smr_pct > 20 )); then
        warn "desktop soft-miss rate ${smr_pct}% over last ${smr_n} runs (>20%) — model is skipping rig.turn_end"
        hint "strengthen system_prompt_prologue (see examples/desktop-chat.json) and re-record; RDR-001 Risk 'instruction drift'. Log: $qlog"
      else
        ok "desktop soft-miss rate ${smr_pct}% over last ${smr_n} runs"
      fi
    fi
  fi
  return 0
}

# --- subcommands (opt-in, mutating; real implementations land in rr-5kf..rr-3zb) ---
# Stubs for now: they announce the not-yet-implemented state + the tracking bead
# and return non-zero so a caller cannot mistake the stub for a completed action.
# The router (_desktop_doctor_dispatch) already wires them so the dispatch
# contract — and the CLI-vs-desktop guard in bin/doctor.sh — can be tested today.
# _desktop_bridge_enable <settings_file>
# Merge {"isEnabled": true} into the per-extension settings JSON, preserving every
# other key (atomic .partial+rename, the trusted-folders.sh precedent). Creates
# the file/parent if absent. Fails loud (rc 1, no .partial) on malformed JSON so
# a corrupt settings file is never silently clobbered.
_desktop_bridge_enable() {
  local settings="$1" tmp
  if [[ ! -s "$settings" ]]; then
    mkdir -p "$(dirname "$settings")"
    printf '{}' >"$settings"
  fi
  tmp="${settings}.partial"
  # jq AND mv must both succeed; a failed mv (full disk, cross-device, perms)
  # must not leave the .partial behind nor be mistaken for success.
  if jq '.isEnabled = true' "$settings" >"$tmp" 2>/dev/null && mv "$tmp" "$settings"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# _desktop_bridge_install_bundle <src_mcpb> <ext_dir>
# Unpack the .mcpb (a zip) into <ext_dir>, the unpacked layout Claude.app expects.
# Stages into a sibling temp dir and renames (same-FS atomic) so a half-unzip
# never lands. Idempotent when the installed content already matches; REFUSES
# (rc 4, no clobber) when a DIFFERENT bridge is installed — the operator updates
# via the Claude.app UI rather than have us overwrite their extension.
_desktop_bridge_install_bundle() {
  local src="$1" ext_dir="$2" parent staging
  if [[ ! -f "$src" ]]; then
    echo "doctor --install-bridge: bundle not found at $src" >&2
    return 4
  fi
  command -v unzip >/dev/null 2>&1 || { echo "doctor --install-bridge: unzip not on PATH" >&2; return 4; }

  # Defense-in-depth (zip-slip): macOS InfoZip unzip does NOT strip ".." entries,
  # so a crafted .mcpb (e.g. via a RIG_BRIDGE_MCPB override) could escape the
  # staging dir on extraction. Refuse any path-traversal or absolute entry first.
  if unzip -Z1 "$src" 2>/dev/null | grep -Eq '(^|/)\.\.(/|$)|^/'; then
    echo "doctor --install-bridge: bundle contains path-traversal or absolute entries — refusing $src" >&2
    return 4
  fi

  parent="$(dirname "$ext_dir")"
  mkdir -p "$parent"
  staging="$(mktemp -d "$parent/.rig-bridge-install.XXXXXX")" || return 4
  if ! unzip -q -o "$src" -d "$staging" 2>/dev/null; then
    rm -rf "$staging"
    echo "doctor --install-bridge: failed to unpack $src" >&2
    return 4
  fi

  if [[ -e "$ext_dir" ]]; then
    if diff -rq "$staging" "$ext_dir" >/dev/null 2>&1; then
      rm -rf "$staging" # already installed, byte-identical — nothing to do
      return 0
    fi
    echo "doctor --install-bridge: a DIFFERENT recording-rig-bridge is already installed at" >&2
    echo "  $ext_dir" >&2
    diff -rq "$staging" "$ext_dir" >&2 || true
    echo "  Refusing to overwrite. Remove or update it in Claude.app Settings > Extensions, then re-run." >&2
    rm -rf "$staging"
    return 4
  fi

  mv "$staging" "$ext_dir" # atomic install
  return 0
}

# desktop_install_bridge (rr-5kf) — file-drop the bridge bundle into the
# Claude-Rig profile and flip its enable flag. Two steps, each refuse-on-collision
# / no-clobber; the bundle install must succeed before the flag is written.
desktop_install_bridge() {
  _desktop_bridge_install_bundle "$RIG_BRIDGE_MCPB" "$RIG_BRIDGE_EXT_DIR" || return $?
  if ! _desktop_bridge_enable "$RIG_BRIDGE_SETTINGS"; then
    echo "doctor --install-bridge: bundle staged but the isEnabled flag write failed ($RIG_BRIDGE_SETTINGS)" >&2
    return 5
  fi
  echo "doctor --install-bridge: recording-rig-bridge installed and enabled"
  echo "  bundle:  $RIG_BRIDGE_EXT_DIR"
  echo "  enabled: $RIG_BRIDGE_SETTINGS"
  echo "  restart Claude-Rig (or launch it) for the extension to load."
  return 0
}

# desktop_install_profile (rr-7u0) — create the isolated Claude-Rig profile and
# (interactively) wait for the operator to log in. REFUSES if any Claude.app is
# running: a concurrent OAuth login across two instances collides (RDR-001 A9).
# The launch + login wait is LIVE-ONLY — gated behind an interactive stdin so the
# tests exercise the guard + dir creation without a real app or a blocking read.
desktop_install_profile() {
  if pgrep -x Claude >/dev/null 2>&1; then
    echo "doctor --install-profile: a Claude.app instance is running — quit it first" >&2
    echo "  (a concurrent OAuth login across instances collides, RDR-001 A9)" >&2
    return 6
  fi
  mkdir -p "$CLAUDE_RIG_DIR"
  echo "doctor --install-profile: created Claude-Rig profile dir at $CLAUDE_RIG_DIR"
  if [[ -t 0 ]]; then
    echo "Launching Claude-Rig — log in, then return here and press Enter."
    open -n -a Claude --args --user-data-dir="$CLAUDE_RIG_DIR" --force-renderer-accessibility
    read -r -p "Press Enter once you have logged in to Claude-Rig... " _
    echo "doctor --install-profile: done — verify with: doctor (desktop checks)"
  else
    echo "doctor --install-profile: non-interactive — skipping the launch + login wait"
    echo "  run this in a terminal to complete login, or use doctor --seed-from-primary"
  fi
  return 0
}

# desktop_seed_from_primary (rr-7u0) — copy the primary profile's web-session
# auth artifacts into the Rig profile (alternative to an interactive login).
# REFUSES if a Claude.app is running (it may be mid-write on these files, A9) and
# no-clobbers if the Rig profile already carries any of them (never overwrite an
# existing session). Copies only artifacts present in the primary, preserving
# mtime (cp -Rp).
desktop_seed_from_primary() {
  if pgrep -x Claude >/dev/null 2>&1; then
    echo "doctor --seed-from-primary: a Claude.app instance is running — quit it first" >&2
    echo "  (it may be writing the auth state you are copying, RDR-001 A9)" >&2
    return 6
  fi
  [[ -d "$RIG_PRIMARY_PROFILE" ]] || {
    echo "doctor --seed-from-primary: primary profile not found at $RIG_PRIMARY_PROFILE" >&2
    return 7
  }
  mkdir -p "$CLAUDE_RIG_DIR"

  local rel
  # Defense-in-depth: RIG_SEED_AUTH_PATHS is env-overridable, so reject any entry
  # that could escape the profile (".." traversal or an absolute path) BEFORE it
  # reaches the mkdir/cp below.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    case "$rel" in
      /* | ../* | */../* | */.. | ..)
        echo "doctor --seed-from-primary: refusing unsafe seed path '$rel' (traversal/absolute)" >&2
        return 2
        ;;
    esac
  done <<< "$RIG_SEED_AUTH_PATHS"

  # No-clobber: refuse if the Rig profile already holds any seed artifact.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ -e "$CLAUDE_RIG_DIR/$rel" ]]; then
      echo "doctor --seed-from-primary: the Rig profile already has auth state ('$rel')" >&2
      echo "  refusing to clobber an existing session — recreate the profile to re-seed" >&2
      return 8
    fi
  done <<< "$RIG_SEED_AUTH_PATHS"

  # Copy each present artifact, preserving mtime.
  local copied=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ -e "$RIG_PRIMARY_PROFILE/$rel" ]]; then
      mkdir -p "$CLAUDE_RIG_DIR/$(dirname "$rel")"
      if ! cp -Rp "$RIG_PRIMARY_PROFILE/$rel" "$CLAUDE_RIG_DIR/$rel"; then
        echo "doctor --seed-from-primary: failed copying '$rel'" >&2
        return 9
      fi
      copied=$((copied + 1))
    fi
  done <<< "$RIG_SEED_AUTH_PATHS"

  echo "doctor --seed-from-primary: seeded $copied auth artifact(s) from the primary profile"
  echo "  $RIG_PRIMARY_PROFILE -> $CLAUDE_RIG_DIR"
  return 0
}
# _desktop_bridge_verify_shape <json_response>
# 0 iff the response matches one of the two known MCP tool-result transport
# shapes (the design gotcha "tool_response shape varies by transport"):
#   - array form (HTTP):  [{"type":"text","text":"..."}]
#   - string form (stdio): a JSON-encoded string
# Anything else is transport drift -> rc 1.
_desktop_bridge_verify_shape() {
  local resp="$1"
  if jq -e 'type=="array" and length>0 and (.[0].type=="text") and (.[0].text|type=="string")' <<<"$resp" >/dev/null 2>&1; then
    return 0
  fi
  if jq -e 'type=="string"' <<<"$resp" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# desktop_verify_bridge (rr-3zb) — spawn the installed bridge server over stdio,
# issue one benign tools/call, and assert the result transport shape. The bridge
# is a standalone line-delimited JSON-RPC node server (no live Claude.app
# needed); rig_emit with no active session writes nothing (orphan-logged), and
# RIG_TMP isolation keeps even that out of the real /tmp namespace. Catches
# server-side transport-format drift before a recording silently mis-reads it.
desktop_verify_bridge() {
  local server="$RIG_BRIDGE_EXT_DIR/server.js"
  if [[ ! -f "$server" ]]; then
    echo "doctor --verify-bridge: bridge server not found at $server" >&2
    echo "  install it first: doctor --install-bridge" >&2
    return 4
  fi
  command -v node >/dev/null 2>&1 || { echo "doctor --verify-bridge: node not on PATH" >&2; return 4; }

  local req resp content tmp
  tmp="$(mktemp -d)"
  req='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rig_emit","arguments":{"name":"__doctor_verify__"}}}'
  resp="$(printf '%s\n' "$req" | RIG_TMP="$tmp" node "$server" 2>/dev/null | head -1)"
  rm -rf "$tmp"

  if [[ -z "$resp" ]]; then
    echo "doctor --verify-bridge: no response from the bridge server" >&2
    return 4
  fi
  # The tool-call payload lives under .result.content (array transport); fall
  # back to .result for transports that hand back the bare value.
  content="$(jq -c '.result.content // .result' <<<"$resp" 2>/dev/null)"
  if _desktop_bridge_verify_shape "$content"; then
    echo "doctor --verify-bridge: bridge responds with a well-formed tool result"
    return 0
  fi
  echo "doctor --verify-bridge: unexpected bridge response shape — possible transport drift" >&2
  echo "  response: $resp" >&2
  return 4
}

# _desktop_write_probe_cache <file> <payload_json>
# Atomically write a timestamped cache record {generated_at, data:<payload>} so
# the doctor freshness checks (_desktop_cache_fresh) can read its mtime and the
# embedded timestamp. .partial+rename; fail loud (rc 1) on a bad payload.
_desktop_write_probe_cache() {
  local file="$1" payload="$2" ts tmp
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$file")"
  tmp="${file}.partial"
  if jq -nc --arg ts "$ts" --argjson body "$payload" '{generated_at:$ts, data:$body}' >"$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# desktop_probe_surfaces (rr-3zb) — LIVE: snapshot the running Claude-Rig AX tree
# (bin/ax-dump) and record per-surface probe state into timestamped caches that
# the doctor freshness checks consume. The AX selectors discovered here are NOT
# auto-promoted into bin/desktop-ax-selectors.json (the driver's hand-tuned
# input) — the operator reviews the cache and promotes deliberately.
desktop_probe_surfaces() {
  # Resolve the running Claude-Rig MAIN pid (carries --user-data-dir, not --type=).
  local pid="" p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    ps -o command= -p "$p" 2>/dev/null | grep -q -- "--type=" || { pid="$p"; break; }
  done < <(pgrep -f -- "--user-data-dir=$CLAUDE_RIG_DIR" 2>/dev/null || true)
  if [[ -z "$pid" ]]; then
    echo "doctor --probe-surfaces: no running Claude-Rig instance found" >&2
    echo "  launch it first (doctor --install-profile), then re-run" >&2
    return 4
  fi
  [[ -x "$RIG_AXDUMP" ]] || {
    echo "doctor --probe-surfaces: ax-dump not built at $RIG_AXDUMP" >&2
    echo "  build it: bin/build-ax-dump.sh" >&2
    return 4
  }

  # One bounded AX snapshot — ax-dump loops, so background it and reap (macOS has
  # no `timeout`). The stub-friendly bound is RIG_PROBE_SECONDS (default 6s).
  local snapfile axpid snapshot
  snapfile="$(mktemp)" || { echo "doctor --probe-surfaces: mktemp failed" >&2; return 4; }
  "$RIG_AXDUMP" "$pid" 1 >"$snapfile" 2>/dev/null &
  axpid=$!
  sleep "${RIG_PROBE_SECONDS:-6}"
  kill "$axpid" 2>/dev/null || true
  wait "$axpid" 2>/dev/null || true
  snapshot="$(cat "$snapfile")"
  rm -f "$snapfile"

  # Selector cache: the AX snapshot text (wrapped as a JSON string).
  _desktop_write_probe_cache "$RIG_SELECTOR_CACHE" "$(jq -Rs '.' <<<"$snapshot")" || return 5
  # Probe cache: per-surface reachability record (pid recorded; surface probes
  # land as the live MCP-probe matures — the cache shape is forward-stable).
  _desktop_write_probe_cache "$RIG_PROBE_CACHE" "$(jq -nc --arg pid "$pid" '{rig_pid:$pid, surfaces:[]}')" || return 5

  echo "doctor --probe-surfaces: wrote probe caches (rig pid $pid)"
  echo "  selectors: $RIG_SELECTOR_CACHE"
  echo "  probe:     $RIG_PROBE_CACHE"
  return 0
}

# _desktop_doctor_dispatch <subcommand> [args...]
# Pure router: map a doctor subcommand flag to its handler, forwarding args.
# Unknown/empty -> stderr usage + return 2. OS-agnostic by design (bin/doctor.sh
# applies the macOS-only guard before calling this, keeping routing testable on
# any platform).
_desktop_doctor_dispatch() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    --install-bridge)    desktop_install_bridge "$@" ;;
    --install-profile)   desktop_install_profile "$@" ;;
    --seed-from-primary) desktop_seed_from_primary "$@" ;;
    --probe-surfaces)    desktop_probe_surfaces "$@" ;;
    --verify-bridge)     desktop_verify_bridge "$@" ;;
    *)
      echo "doctor: unknown subcommand '${sub:-(none)}'" >&2
      echo "  valid: --install-bridge --install-profile --seed-from-primary --probe-surfaces --verify-bridge" >&2
      return 2
      ;;
  esac
}
