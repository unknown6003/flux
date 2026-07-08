#!/bin/bash
# Builds Flux.app — a self-contained, ad-hoc-signed menu bar agent.
#
#   ./Scripts/build_app.sh [debug|release]
#
# Output: build/Flux.app
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Flux"
BUNDLE_ID="com.flux.menubar"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "▶ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▶ Rendering app icon…"
ICONSET="$OUT_DIR/AppIcon.iconset"
swift "$ROOT/Scripts/generate_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"

echo "▶ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$OUT_DIR/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "▶ Ad-hoc signing…"
# Ad-hoc signing gives the bundle a stable code identity so Login Items and TCC
# permissions persist across launches. A real Developer ID cert would replace
# the "-" for notarised distribution.
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"

echo "✓ Built $APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /' || true
