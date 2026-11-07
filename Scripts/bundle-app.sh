#!/bin/bash
# Assembles build/SwiftExile.app from the SwiftPM executable and the upstream renderer build.
# Usage: Scripts/bundle-app.sh [debug|release]   (set SKIP_RENDERER=1 to reuse an existing dist/)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SwiftExile.app"
DIST="$ROOT/upstream/renderer/dist"

cd "$ROOT"
if [ "${SKIP_RENDERER:-0}" != "1" ] || [ ! -f "$DIST/index.html" ]; then
  "$ROOT/Scripts/build-renderer.sh"
fi

if [ "$CONFIG" = "release" ]; then
  swift build -c release --arch arm64 --arch x86_64 --product SwiftExile
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c debug --product SwiftExile
  BIN_DIR="$(swift build -c debug --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SwiftExile" "$APP/Contents/MacOS/SwiftExile"
if [ "$CONFIG" = "release" ]; then
  # Drop debug and local symbols (smaller binary). No dSYM is kept yet; add one before public releases.
  strip -S -x "$APP/Contents/MacOS/SwiftExile"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Record which upstream release the renderer comes from (shown in the About page and logs).
UPSTREAM_VERSION="$(/usr/bin/plutil -extract version raw -o - "$ROOT/upstream/main/package.json" 2>/dev/null || echo unknown)"
UPSTREAM_SHA="$(git -C "$ROOT/upstream" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Set :EE2UpstreamVersion $UPSTREAM_VERSION ($UPSTREAM_SHA)" "$APP/Contents/Info.plist"

rsync -a --delete --exclude '*.map' "$DIST/" "$APP/Contents/Resources/renderer/"
cp "$ROOT/upstream/main/build/icons/icon.png" "$APP/Contents/Resources/icon.png"

# Upstream license must ship with the bundled renderer (MIT).
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/upstream/LICENSE" "$APP/Contents/Resources/Licenses/ExiledExchange2-LICENSE.txt"

# Ad-hoc signature for local builds. Release builds will use the self-signed certificate (plan §3.4).
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "built $APP ($CONFIG, EE2 $UPSTREAM_VERSION $UPSTREAM_SHA)"
