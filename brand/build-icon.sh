#!/bin/bash
# Rebuilds Aside.icns from icon.svg. Run after editing the mark.
set -euo pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Aside.iconset"

qlmanage -t -s 1024 -o "$WORK" icon.svg >/dev/null 2>&1
cp "$WORK/icon.svg.png" aside-icon-1024.png

# Note: this reads size and name as separate fields. zsh does not word-split an
# unquoted variable, so `set -- $line` silently yields one field there.
while read -r size name; do
  [ -z "$size" ] && continue
  sips -z "$size" "$size" aside-icon-1024.png --out "$WORK/Aside.iconset/$name.png" >/dev/null
done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES

iconutil -c icns "$WORK/Aside.iconset" -o Aside.icns
echo "Rebuilt Aside.icns"
