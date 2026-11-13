#!/bin/bash
# Regenerate AppIcon.icns / AppIcon.iconset from icon-master-1024.png
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/gui/icon-master-1024.png"
ICONSET="$ROOT/gui/AppIcon.iconset"
mkdir -p "$ICONSET"
sizes=(16 32 128 256 512)
for sz in "${sizes[@]}"; do
  sips -z $sz $sz "$MASTER" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$MASTER" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/gui/AppIcon.icns"
echo "OK: gui/AppIcon.icns regenerated"
