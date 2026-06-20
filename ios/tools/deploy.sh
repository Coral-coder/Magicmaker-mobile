#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-Release}"
"$ROOT/tools/build_device.sh" "$CONFIG"

PRODUCTS="Release-iphoneos"
if [[ "$CONFIG" == "Debug" ]]; then
  PRODUCTS="Debug-iphoneos"
fi

APP=$(find ~/Library/Developer/Xcode/DerivedData/MagicMaker-*/Build/Products/"$PRODUCTS"/MagicMaker.app -maxdepth 0 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
  echo "MagicMaker.app not found after build." >&2
  exit 1
fi

DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /iPhone/ { print $3; exit }')
if [[ -z "$DEVICE" ]]; then
  echo "Built: $APP"
  echo "No connected iOS device found. Plug in iPhone and retry, or install from Xcode."
  exit 1
fi

echo "Installing to $DEVICE …"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Done."
