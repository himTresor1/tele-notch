#!/bin/zsh
# Packs build/TeleNotch.app into release/TeleNotch.dmg: a window with the app, an arrow,
# and an Applications shortcut, plus first-launch help in the background.
# Usage: ./scripts/make-dmg.sh [signing identity]
set -euo pipefail
cd "${0:A:h}/.."
ID="${1:-Apple Development}"
security find-identity -v -p codesigning | grep -q "$ID" || ID="-"
APP=build/TeleNotch.app
[ -d "$APP" ] || { echo "Build the app first (./build.sh)"; exit 1; }
VOL="TeleNotch"
OUT=release/TeleNotch.dmg
STAGE=$(mktemp -d)/stage
RW=$(mktemp -d)/rw.dmg
trap 'hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true' EXIT

# Background at 1× and 2× in one TIFF so it's sharp on Retina screens.
swift scripts/dmg-background.swift dmg >/dev/null
tiffutil -cathidpicheck dmg/background.png dmg/background@2x.png -out dmg/background.tiff >/dev/null

mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/TeleNotch.app"
ln -s /Applications "$STAGE/Applications"
cp dmg/background.tiff "$STAGE/.background/background.tiff"

hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"

# Ask Finder to lay out the window once; it saves the layout inside the image.
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set w to container window
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 860, 568}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 112
    set text size of o to 13
    set background picture of o to file ".background:background.tiff"
    set position of item "TeleNotch.app" of w to {170, 170}
    set position of item "Applications" of w to {490, 170}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
rm -rf "/Volumes/$VOL/.fseventsd"; sync
hdiutil detach -quiet "/Volumes/$VOL"

mkdir -p release
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
codesign --force --timestamp=none -s "$ID" "$OUT"
echo "built $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
