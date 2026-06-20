#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tools/icon_source.png"
ICONSET="$ROOT/MagicMaker/Assets.xcassets/AppIcon.appiconset"
OUT="$ICONSET/AppIcon.png"

if [[ ! -f "$SRC" ]]; then
  echo "Missing icon source: $SRC" >&2
  exit 1
fi

mkdir -p "$ICONSET"

if command -v magick >/dev/null 2>&1; then
  magick "$SRC" -resize 1024x1024 "$OUT"
elif command -v convert >/dev/null 2>&1; then
  convert "$SRC" -resize 1024x1024 "$OUT"
else
  sips -z 1024 1024 "$SRC" --out "$OUT" >/dev/null
fi

cat > "$ICONSET/Contents.json" <<'EOF'
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "Wrote $ICONSET/Contents.json"

echo "App icon ready: $OUT"
