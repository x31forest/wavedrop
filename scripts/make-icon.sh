#!/bin/zsh
# Regenerates Resources/AppIcon.icns from a rendered Wavedrop frame.
set -e
cd "${0:a:h}/.."
swift build -c release
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
.build/release/Wavedrop --icon "$TMP/icon_1024.png"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" Resources/AppIcon.png
echo "Wrote Resources/AppIcon.icns"
