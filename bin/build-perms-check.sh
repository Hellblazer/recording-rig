#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build the TCC preflight reporter and stage it at bin/perms-check (rr-2pp.6.1.1).
# perms-check is a doctor helper that prints {accessibility,screenRecording} for
# the controlling process; the compiled Mach-O is a build artifact (gitignored),
# the SwiftPM source under desktop-driver/Sources/perms-check/ is the source of
# truth. Mirrors bin/build-ax-dump.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$HERE/desktop-driver"

command -v swift >/dev/null 2>&1 || { echo "build-perms-check: swift not found on PATH" >&2; exit 1; }

echo "[build-perms-check] swift build -c release --product perms-check ($PKG)"
swift build --package-path "$PKG" -c release --product perms-check

PRODUCT="$(swift build --package-path "$PKG" -c release --show-bin-path)/perms-check"
[[ -x "$PRODUCT" ]] || { echo "build-perms-check: product not found at $PRODUCT" >&2; exit 1; }

cp "$PRODUCT" "$HERE/bin/perms-check"
echo "[build-perms-check] staged -> $HERE/bin/perms-check"
echo "[build-perms-check] usage: bin/perms-check | jq ."
