#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Desktop-backend render (RDR-001 Phase 2 Step 2, rr-2pp.3.2): the h264 .mov
# produced by bin/desktop-driver (ScreenCaptureKit + AVAssetWriter) -> .mp4 + .gif.
# Analogue of the CLI rig's `agg` step. record.sh's desktop dispatch (rr-2pp.3.3)
# calls this ONLY on the validate.mjs PASS path — the render stays gated behind
# validation, exactly like the CLI `agg` gate (bin/record.sh:291).
#
# Usage: render-webm.sh <in.mov> <out.mp4> <out.gif>
# Env: SKIP_GIF=1 skip the .gif, SKIP_MP4=1 skip the .mp4, RENDER_FPS (default 12).
set -euo pipefail

IN="${1:?usage: render-webm.sh <in.mov> <out.mp4> <out.gif>}"
MP4="${2:?usage: render-webm.sh <in.mov> <out.mp4> <out.gif>}"
GIF="${3:?usage: render-webm.sh <in.mov> <out.mp4> <out.gif>}"
FPS="${RENDER_FPS:-12}"

[[ -f "$IN" ]] || { echo "render-webm: input .mov not found: $IN" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "render-webm: ffmpeg not found (run bin/doctor.sh)" >&2; exit 1; }
[[ "$FPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "render-webm: RENDER_FPS must be numeric, got: $FPS" >&2; exit 1; }
if [[ "${SKIP_MP4:-0}" == "1" && "${SKIP_GIF:-0}" == "1" ]]; then
  echo "render-webm: SKIP_MP4=1 and SKIP_GIF=1 — nothing to render" >&2
fi

WORK=""
# Must end with a success status: as the EXIT trap's last command under `set -e`,
# a non-zero return here would make the script exit non-zero even on success.
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# .mp4 — the .mov is already h264, so stream-copy (no re-encode). Transcode only
# if the remux fails (e.g. an unusual container quirk).
if [[ "${SKIP_MP4:-0}" != "1" ]]; then
  if ffmpeg -y -loglevel error -i "$IN" -c copy "$MP4" 2>/dev/null; then
    echo "[render-webm] mp4 (stream-copy) -> $MP4"
  else
    echo "[render-webm] remux failed; transcoding .mp4" >&2
    ffmpeg -y -loglevel error -i "$IN" -c:v libx264 -pix_fmt yuv420p "$MP4"
    echo "[render-webm] mp4 (transcoded) -> $MP4"
  fi
fi

# .gif — gifski (higher quality, the listed dep) when present; otherwise the
# zero-extra-dependency ffmpeg two-pass palette. Either way, fps is clamped to
# keep the GIF small (parity with the CLI rig's agg defaults).
if [[ "${SKIP_GIF:-0}" != "1" ]]; then
  WORK="$(mktemp -d)"
  if command -v gifski >/dev/null 2>&1; then
    ffmpeg -y -loglevel error -i "$IN" -vf "fps=${FPS}" "$WORK/frame%05d.png"
    shopt -s nullglob
    frames=("$WORK"/frame*.png)
    shopt -u nullglob
    [[ ${#frames[@]} -gt 0 ]] || { echo "render-webm: no frames extracted from $IN" >&2; exit 1; }
    gifski -o "$GIF" --fps "$FPS" "${frames[@]}"
    echo "[render-webm] gif (gifski) -> $GIF"
  else
    ffmpeg -y -loglevel error -i "$IN" -vf "fps=${FPS},palettegen" "$WORK/palette.png"
    ffmpeg -y -loglevel error -i "$IN" -i "$WORK/palette.png" \
      -lavfi "fps=${FPS},paletteuse" "$GIF"
    echo "[render-webm] gif (ffmpeg palette) -> $GIF"
  fi
fi
