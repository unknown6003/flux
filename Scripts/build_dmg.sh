#!/bin/bash
# Builds Flux.app (release) and packages it into a distributable disk image
# with an Applications shortcut for drag-to-install.
#
#   ./Scripts/build_dmg.sh
#
# Output: build/Flux.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Flux"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/$APP_NAME.app"
DMG="$OUT_DIR/$APP_NAME.dmg"
STAGE="$OUT_DIR/dmg-stage"

# Build the signed .app first.
"$ROOT/Scripts/build_app.sh" release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "▶ Staging disk image…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▶ Creating ${DMG}…"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"
SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "✓ Built $DMG ($SIZE, v$VERSION)"
