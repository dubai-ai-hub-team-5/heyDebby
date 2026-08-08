#!/bin/bash
# Regenerate assets/AppIcon.icns from a 1024px master PNG, styled as a native macOS
# icon (Big Sur grid: 824px rounded-square art centered on a 1024 canvas with a 100px
# margin). Run this only when the artwork changes; build.sh just copies the .icns.
#
# Usage: ./make-icon.sh [path/to/master-1024.png]   (defaults to the dark master)
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-assets/debby-icon.png}"   # 1024x1024 master (dark by default)
[ -f "$SRC" ] || { echo "No master at $SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROUNDED="$TMP/appicon-1024.png"

python3 - "$SRC" "$ROUNDED" <<'PY'
import sys
from PIL import Image, ImageDraw
src_path, out_path = sys.argv[1], sys.argv[2]
CANVAS, ART, RADIUS = 1024, 824, 185
margin = (CANVAS - ART) // 2
src = Image.open(src_path).convert("RGBA").resize((ART, ART), Image.LANCZOS)
mask = Image.new("L", (ART, ART), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, ART - 1, ART - 1], radius=RADIUS, fill=255)
canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
canvas.paste(src, (margin, margin), mask)
canvas.save(out_path)
PY

ICONSET="$TMP/Debby.iconset"
mkdir -p "$ICONSET"
for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $pair
  sips -z "$1" "$1" "$ROUNDED" --out "$ICONSET/icon_$2.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
echo "Wrote assets/AppIcon.icns ($(du -h assets/AppIcon.icns | cut -f1))"
