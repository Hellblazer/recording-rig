# SPDX-License-Identifier: MIT
#
# Code-surface trusted-folder pre-seeding (RDR-001 Phase 4 Step 3, rr-2pp.5.3).
# Sourced by bin/record.sh. Claude.app's local-agent-mode (Code surface) gates
# each untrusted working folder behind a per-folder trust dialog; if that dialog
# fires mid-recording the run stalls waiting on a click. record.sh merges the
# spec's desktop.trusted_folders into the profile config's
# `localAgentModeTrustedFolders` array BEFORE launching Claude.app so no dialog
# appears.
#
# Storage: the key lives in Claude.app's electron-store config — its default
# store is <user-data-dir>/config.json, which is plaintext and already holds the
# sibling app settings (userThemeMode, locale, ...). The asar normalizes folder
# paths by stripping trailing slashes (GV=e=>e.replace(/[\/]+$/,"")) and dedupes
# by exact-or-subpath; we mirror the normalize + exact-dedup here. The exact
# store target is re-verified at the rr-2pp.5.5 live gate (the key starts empty,
# so it is not statically observable in a fresh profile).

# trusted_folders_seed <config_json> <folder>...
# Merge the given folder paths into config_json's localAgentModeTrustedFolders
# array — normalized (trailing slashes stripped) and de-duplicated — creating the
# file/key if absent and preserving every other key. Atomic .partial + rename.
# No-op (rc 0) when no folders are given.
trusted_folders_seed() {
  local config="$1"
  shift
  (( $# > 0 )) || return 0

  # Ensure a JSON object to merge into (a brand-new profile may lack the file).
  if [[ ! -s "$config" ]]; then
    mkdir -p "$(dirname "$config")"
    printf '{}' >"$config"
  fi

  # JSON array of the new folders, trailing slashes stripped (asar GV()).
  local add_json
  add_json="$(printf '%s\n' "$@" | jq -R 'sub("/+$"; "")' | jq -s '.')" || return 1

  # Dedup is exact-match-after-normalize (jq `unique`), intentionally simpler than
  # the asar's subpath dedup (startsWith(r+sep)). For SEEDING that is harmless: a
  # redundant subpath entry still trusts the folder, so no dialog fires either way.
  local tmp="${config}.partial"
  if jq --argjson add "$add_json" '
    .localAgentModeTrustedFolders =
      ( ((.localAgentModeTrustedFolders // []) | map(sub("/+$"; ""))) + $add
        | unique )
  ' "$config" >"$tmp"; then
    mv "$tmp" "$config"
  else
    rm -f "$tmp" # never leave a partial config behind on a jq failure
    return 1
  fi
}
