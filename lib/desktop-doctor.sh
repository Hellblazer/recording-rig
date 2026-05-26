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
# Probe caches written by `doctor --probe-surfaces` (rr-3zb); their freshness is
# how doctor knows the AX selectors + per-surface MCP probe were last validated
# against the live app. Absent until --probe-surfaces has run in this profile.
: "${RIG_SELECTOR_CACHE:=$CLAUDE_RIG_DIR/.recording-rig/ax-selectors.probe.json}"
: "${RIG_PROBE_CACHE:=$CLAUDE_RIG_DIR/.recording-rig/surface-probe.json}"

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
  if jq '.isEnabled = true' "$settings" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"
    return 1
  fi
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

desktop_install_profile()   { echo "doctor --install-profile: not yet implemented (rr-7u0)" >&2; return 3; }
desktop_seed_from_primary() { echo "doctor --seed-from-primary: not yet implemented (rr-7u0)" >&2; return 3; }
desktop_probe_surfaces()    { echo "doctor --probe-surfaces: not yet implemented (rr-3zb)" >&2; return 3; }
desktop_verify_bridge()     { echo "doctor --verify-bridge: not yet implemented (rr-3zb)" >&2; return 3; }

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
