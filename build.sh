#!/bin/zsh
# Builds build/TeleNotch.app and signs it inside-out (hardened runtime).
# Usage: ./build.sh [signing identity]   default "Apple Development" (falls back to ad-hoc "-").
set -euo pipefail
cd "${0:A:h}"
ID="${1:-Apple Development}"
security find-identity -v -p codesigning | grep -q "$ID" || ID="-"
APP=build/TeleNotch.app
./scripts/fetch-sparkle.sh

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TeleNotch"

rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Frameworks
cp "$BIN" $APP/Contents/MacOS/TeleNotch
ditto vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework $APP/Contents/Frameworks/Sparkle.framework
otool -l $APP/Contents/MacOS/TeleNotch | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" $APP/Contents/MacOS/TeleNotch
cp Info.plist $APP/Contents/
[ -f feed-url.txt ] && plutil -insert SUFeedURL -string "$(tr -d '[:space:]' < feed-url.txt)" $APP/Contents/Info.plist
cp AppIcon.icns $APP/Contents/Resources/

TS="--timestamp=none"; [[ "$ID" == Developer\ ID* ]] && TS="--timestamp"
sign() { codesign --force --options runtime $TS -s "$ID" "$@"; }
FWV=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
# Sparkle's documented order for a non-sandboxed app; Downloader.xpc keeps its own entitlements.
sign "$FWV/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FWV/XPCServices/Downloader.xpc"
sign "$FWV/Autoupdate"
sign "$FWV/Updater.app"
sign $APP/Contents/Frameworks/Sparkle.framework
sign --entitlements TeleNotch.entitlements $APP
codesign --verify --strict --deep $APP && echo "built $APP (signed: $ID)"
