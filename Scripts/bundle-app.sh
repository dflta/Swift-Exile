#!/bin/bash
# Assembles build/SwiftExile.app from the SwiftPM executable and the upstream renderer build.
# Usage: Scripts/bundle-app.sh [debug|release]
#   SKIP_RENDERER=1           reuse an existing renderer and engine build
#   SWIFTEXILE_VERSION=1.2.3  version to stamp (CFBundleShortVersionString); default from Info.plist
#   SWIFTEXILE_BUILD=42       build number (CFBundleVersion, what Sparkle compares)
#   SIGN=release              sign with the release certificate (Scripts/sign-app.sh); release
#                             builds do this by default, debug builds are signed ad hoc
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SwiftExile.app"
DIST="$ROOT/upstream/renderer/dist"

cd "$ROOT"
if [ "${SKIP_RENDERER:-0}" != "1" ] || [ ! -f "$DIST/index.html" ] || [ ! -f "$ROOT/Engine/dist/engine.js" ]; then
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
# Sparkle (auto-updates); the executable finds it through @executable_path/../Frameworks.
mkdir -p "$APP/Contents/Frameworks"
rsync -a --delete "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
if [ "$CONFIG" = "release" ]; then
  # Drop debug and local symbols (smaller binary). No dSYM is kept yet; add one before public releases.
  strip -S -x "$APP/Contents/MacOS/SwiftExile"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${SWIFTEXILE_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SWIFTEXILE_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${SWIFTEXILE_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SWIFTEXILE_BUILD" "$APP/Contents/Info.plist"
fi

# Record which upstream release the renderer comes from (shown in the About page and logs).
UPSTREAM_VERSION="$(/usr/bin/plutil -extract version raw -o - "$ROOT/upstream/main/package.json" 2>/dev/null || echo unknown)"
UPSTREAM_SHA="$(git -C "$ROOT/upstream" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Set :EE2UpstreamVersion $UPSTREAM_VERSION ($UPSTREAM_SHA)" "$APP/Contents/Info.plist"

rsync -a --delete --exclude '*.map' "$DIST/" "$APP/Contents/Resources/renderer/"
# Headless price-check engine, served at /engine/ next to the renderer.
mkdir -p "$APP/Contents/Resources/renderer/engine"
cp "$ROOT/Engine/index.html" "$ROOT/Engine/dist/engine.js" "$APP/Contents/Resources/renderer/engine/"
cp "$ROOT/upstream/main/build/icons/icon.png" "$APP/Contents/Resources/icon.png"
# Menu bar icon (vector, made from Resources/StatusIcon.svg by Scripts/make-status-icon.swift).
cp "$ROOT/Resources/StatusIcon.pdf" "$APP/Contents/Resources/StatusIcon.pdf"

# App icon for Finder, the Dock, and the DMG (Info.plist: CFBundleIconFile = AppIcon), from the
# 1024 px master in Resources/AppIcon.png (made by Scripts/make-app-icon.swift).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Licenses of everything bundled (THIRD_PARTY_NOTICES.md).
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES/swift-packages" "$LICENSES/npm"
cp "$ROOT/LICENSE" "$LICENSES/SwiftExile-LICENSE.txt"
cp "$ROOT/upstream/LICENSE" "$LICENSES/ExiledExchange2-LICENSE.txt"
# Swift packages linked into the app (Hummingbird, SwiftNIO, Sparkle, ...): license and NOTICE files.
for package in "$ROOT"/.build/checkouts/*/; do
  name="$(basename "$package")"
  for file in "$package"LICENSE* "$package"NOTICE*; do
    [ -f "$file" ] && cp "$file" "$LICENSES/swift-packages/$name-$(basename "$file" | sed 's/\.[^.]*$//').txt"
  done
done
# npm packages compiled into the renderer (production dependencies only).
(cd "$ROOT/upstream/renderer" && npm ls --omit=dev --all --parseable 2>/dev/null | tail -n +2) | while read -r dir; do
  for file in "$dir"/LICEN[SC]E* "$dir"/NOTICE*; do
    if [ -f "$file" ]; then
      name="$(basename "$dir")"; scope="$(basename "$(dirname "$dir")")"
      case "$scope" in @*) name="$scope-$name" ;; esac
      cp "$file" "$LICENSES/npm/$name-$(basename "$file" | sed 's/\.[^.]*$//').txt"
    fi
  done
done

# Release builds: the self-signed release certificate (keeps users' permissions across updates).
# Local debug builds: ad hoc.
if [ "${SIGN:-$([ "$CONFIG" = release ] && echo release || echo adhoc)}" = "release" ]; then
  "$ROOT/Scripts/sign-app.sh" "$APP"
else
  codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null
  codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
echo "built $APP $VERSION ($CONFIG, EE2 $UPSTREAM_VERSION $UPSTREAM_SHA)"
