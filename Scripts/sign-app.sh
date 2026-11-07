#!/bin/bash
# Signs SwiftExile.app with the release certificate (plan §3.4), using a throwaway keychain so the
# login keychain is never touched.
#
# Usage: Scripts/sign-app.sh build/SwiftExile.app
#
# Where the certificate comes from (first match wins):
#   - CI: SWIFTEXILE_P12_BASE64 + SWIFTEXILE_P12_PASSWORD (GitHub Actions secrets)
#   - local: $SWIFTEXILE_RELEASE_DIR (default ~/.swiftexile-release, from create-release-identity.sh)
#
# Afterwards the app's designated requirement must match Resources/designated-requirement.txt:
# a different certificate would make macOS forget every user's Accessibility permission.
set -euo pipefail

APP="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${SWIFTEXILE_RELEASE_DIR:-$HOME/.swiftexile-release}"
ENTITLEMENTS="$ROOT/Resources/SwiftExile.entitlements"
EXPECTED_DR="$ROOT/Resources/designated-requirement.txt"

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/signing.keychain-db"
KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -base64 18)"
cleanup() {
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ -n "${SWIFTEXILE_P12_BASE64:-}" ]; then
  printf '%s' "$SWIFTEXILE_P12_BASE64" | base64 --decode > "$WORK/identity.p12"
  P12_PASSWORD="${SWIFTEXILE_P12_PASSWORD:?SWIFTEXILE_P12_PASSWORD is not set}"
else
  cp "$DIR/SwiftExile-Release.p12" "$WORK/identity.p12"
  P12_PASSWORD="$(cat "$DIR/p12-password.txt")"
fi

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock while signing
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# The certificate is self-signed (not trusted by the system), so select it by its SHA-1 hash.
IDENTITY="$(security find-identity -v "$KEYCHAIN" 2>/dev/null | awk '/SwiftExile Release/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity "$KEYCHAIN" | awk '/SwiftExile Release/ {print $2; exit}')"
fi
[ -n "$IDENTITY" ] || { echo "error: SwiftExile Release identity not found" >&2; exit 1; }

sign() {
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$@"
}

# Nested code first, innermost out (no --deep: it signs things in the wrong order).
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for item in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/XPCServices/Downloader.xpc" \
              "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    [ -e "$item" ] && sign --options runtime "$item"
  done
  sign --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
fi
sign --options runtime --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --strict --deep "$APP"
ACTUAL_DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
if [ -f "$EXPECTED_DR" ]; then
  if [ "$ACTUAL_DR" != "$(cat "$EXPECTED_DR")" ]; then
    echo "error: designated requirement changed — this would reset users' Accessibility permission." >&2
    echo "  expected: $(cat "$EXPECTED_DR")" >&2
    echo "  actual:   $ACTUAL_DR" >&2
    exit 1
  fi
else
  printf '%s\n' "$ACTUAL_DR" > "$EXPECTED_DR"
  echo "recorded the designated requirement in $EXPECTED_DR (commit it)"
fi
echo "signed $APP with SwiftExile Release"
