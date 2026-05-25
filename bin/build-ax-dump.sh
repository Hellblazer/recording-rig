#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build the read-only AX-tree dumper and stage it at bin/ax-dump (rr-2pp.5.1).
# ax-dump is a discovery helper for authoring bin/desktop-ax-selectors.json on
# new surfaces; the compiled Mach-O is a build artifact (gitignored), the
# SwiftPM source under desktop-driver/Sources/ax-dump/ is the source of truth.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$HERE/desktop-driver"

command -v swift >/dev/null 2>&1 || { echo "build-ax-dump: swift not found on PATH" >&2; exit 1; }

echo "[build-ax-dump] swift build -c release --product ax-dump ($PKG)"
swift build --package-path "$PKG" -c release --product ax-dump

PRODUCT="$(swift build --package-path "$PKG" -c release --show-bin-path)/ax-dump"
[[ -x "$PRODUCT" ]] || { echo "build-ax-dump: product not found at $PRODUCT" >&2; exit 1; }

cp "$PRODUCT" "$HERE/bin/ax-dump"
echo "[build-ax-dump] staged -> $HERE/bin/ax-dump"
echo "[build-ax-dump] usage: bin/ax-dump \$(pgrep -x Claude-Rig)"
