#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-Release}"

echo "Cleaning prior device build output…"
xcodebuild -scheme MagicMaker -configuration "$CONFIG" -destination 'generic/platform=iOS' clean >/dev/null

echo "Building MagicMaker for iPhone ($CONFIG, no debug dylib)…"
xcodebuild \
  -scheme MagicMaker \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  ENABLE_DEBUG_DYLIB=NO \
  ENABLE_PREVIEWS=NO \
  build

PRODUCTS="Release-iphoneos"
if [[ "$CONFIG" == "Debug" ]]; then
  PRODUCTS="Debug-iphoneos"
fi

APP=$(find ~/Library/Developer/Xcode/DerivedData/MagicMaker-*/Build/Products/"$PRODUCTS"/MagicMaker.app -maxdepth 0 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
  echo "Build succeeded but MagicMaker.app not found." >&2
  exit 1
fi

if otool -L "$APP/MagicMaker" | rg -q "MagicMaker.debug.dylib"; then
  echo "ERROR: Device build still links MagicMaker.debug.dylib — launch will crash." >&2
  exit 1
fi

if otool -L "$APP/MagicMaker" | rg -q "DeveloperToolsSupport"; then
  echo "ERROR: Device build links DeveloperToolsSupport — launch will crash on device." >&2
  exit 1
fi

echo "OK: $APP"
echo "Install from Xcode (Run) or: xcrun devicectl device install app --device <UDID> \"$APP\""
