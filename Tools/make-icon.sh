#!/bin/bash
# Renders Tools/icon.swift into Resources/AppIcon.icns and Resources/icon.png (used by the README).
set -euo pipefail
cd "$(dirname "$0")/.."
swift Tools/icon.swift Resources/icon.png
SET=build/AppIcon.iconset
rm -rf "$SET" && mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/icon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Made Resources/AppIcon.icns"
