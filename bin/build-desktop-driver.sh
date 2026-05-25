#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build the Swift desktop driver and stage the binary at bin/desktop-driver
# (the path record.sh's desktop dispatch execs — rr-2pp.3.3). The compiled
# Mach-O is a build artifact (gitignored); the SwiftPM sources under
# desktop-driver/ are the committed source of truth.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$HERE/desktop-driver"

command -v swift >/dev/null 2>&1 || { echo "build-desktop-driver: swift not found on PATH" >&2; exit 1; }

echo "[build-desktop-driver] swift build -c release ($PKG)"
swift build --package-path "$PKG" -c release

PRODUCT="$(swift build --package-path "$PKG" -c release --show-bin-path)/desktop-driver"
[[ -x "$PRODUCT" ]] || { echo "build-desktop-driver: product not found at $PRODUCT" >&2; exit 1; }

cp "$PRODUCT" "$HERE/bin/desktop-driver"
echo "[build-desktop-driver] staged -> $HERE/bin/desktop-driver"
