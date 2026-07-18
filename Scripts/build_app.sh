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
VENDOR_MRA="$ROOT/Vendor/mediaremote-adapter"
MRA_BUILD_DIR="$OUT_DIR/mediaremote-adapter-build"

echo "▶ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▶ Rendering app icon…"
ICONSET="$OUT_DIR/AppIcon.iconset"
swift "$ROOT/Scripts/generate_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"

# Builds the vendored MediaRemoteAdapter.framework from source (see
# Vendor/mediaremote-adapter/PROVENANCE.md) so Now Playing can read/control
# media on macOS 15.4+, where Apple blocks the private MediaRemote framework
# for ordinary app processes. This mirrors upstream's own build recipe
# (a plain out-of-tree CMake build). If `cmake` isn't installed, or the build
# fails for any reason, we skip it with a warning rather than failing the
# whole app build — NowPlayingService falls back to AppleScript at runtime
# when the framework/script aren't bundled, so this is a soft dependency.
MRA_FRAMEWORK=""
if command -v cmake >/dev/null 2>&1; then
  echo "▶ Building MediaRemoteAdapter.framework…"
  if cmake -S "$VENDOR_MRA" -B "$MRA_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release \
        >"$MRA_BUILD_DIR.log" 2>&1 \
     && cmake --build "$MRA_BUILD_DIR" --target MediaRemoteAdapter --config Release \
        >>"$MRA_BUILD_DIR.log" 2>&1; then
    CANDIDATE="$MRA_BUILD_DIR/MediaRemoteAdapter.framework"
    if [ -d "$CANDIDATE" ]; then
      MRA_FRAMEWORK="$CANDIDATE"
    else
      echo "⚠ MediaRemoteAdapter.framework build reported success but the framework is missing — skipping Now Playing adapter"
    fi
  else
    echo "⚠ MediaRemoteAdapter.framework build failed — Now Playing will fall back to AppleScript only. See $MRA_BUILD_DIR.log"
  fi
else
  echo "⚠ cmake not found — skipping MediaRemoteAdapter.framework build (Now Playing will fall back to AppleScript only)"
fi

echo "▶ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$OUT_DIR/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ -n "$MRA_FRAMEWORK" ]; then
  echo "▶ Bundling MediaRemoteAdapter…"
  mkdir -p "$CONTENTS/Frameworks"
  rm -rf "$CONTENTS/Frameworks/MediaRemoteAdapter.framework"
  cp -R "$MRA_FRAMEWORK" "$CONTENTS/Frameworks/MediaRemoteAdapter.framework"
  cp "$VENDOR_MRA/bin/mediaremote-adapter.pl" "$CONTENTS/Resources/mediaremote-adapter.pl"
fi

echo "▶ Ad-hoc signing…"
# Ad-hoc signing gives the bundle a stable code identity so Login Items and TCC
# permissions persist across launches. A real Developer ID cert would replace
# the "-" for notarised distribution.
#
# Signed inside-out and WITHOUT --deep: the framework is a nested bundle that
# must carry its own valid signature before the outer app is signed, or a
# plain --deep re-sign can silently paper over a broken nested signature.
# Signing the app on its own (no --deep) only touches the app's own
# executable/Info.plist and leaves the framework's signature exactly as it
# was, so if the framework failed to build (and isn't bundled) this step is
# unaffected either way.
if [ -d "$CONTENTS/Frameworks/MediaRemoteAdapter.framework" ]; then
  codesign --force --sign - "$CONTENTS/Frameworks/MediaRemoteAdapter.framework"
fi
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "✓ Built $APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /' || true
