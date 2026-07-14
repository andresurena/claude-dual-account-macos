#!/bin/zsh
#
# Builds a proper multi-resolution .icns from a single square source image
# (PNG or anything `sips` can read). Producing all 10 sizes macOS expects
# looks noticeably crisper than handing macOS one 1024px image and letting
# it bilinearly downscale for the Dock/Finder/menu bar.
#
# Usage:
#   ./build-icns-from-image.sh source-image.png output.icns

set -euo pipefail

SRC="${1:?Source image required, e.g. logo-1024.png}"
OUT="${2:?Output .icns path required, e.g. my-icon.icns}"

if [ ! -f "$SRC" ]; then
  echo "Source image not found: $SRC"
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
ICONSET="$WORKDIR/icon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns -o "$OUT" "$ICONSET"
echo "Wrote $OUT"
