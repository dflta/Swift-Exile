#!/bin/bash
# Adds the new DMG to the Sparkle appcast and signs it with the EdDSA key (plan §3.4).
#
# Usage: Scripts/make-appcast.sh build/SwiftExile-1.2.3.dmg v1.2.3 [previous-appcast.xml]
#
# Writes build/appcast/appcast.xml. Pass the previous release's appcast.xml so older entries are
# kept. The version's CHANGELOG.md section is embedded as the update's release notes (shown in the
# update dialog). The key comes from SPARKLE_ED25519_PRIVATE (CI secret) or
# $SWIFTEXILE_RELEASE_DIR/sparkle-ed25519-private.txt (local, from create-release-identity.sh).
set -euo pipefail

DMG="$1"
TAG="$2"
PREVIOUS="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${SWIFTEXILE_RELEASE_DIR:-$HOME/.swiftexile-release}"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
OUT="$ROOT/build/appcast"

[ -x "$TOOLS/generate_appcast" ] || swift package --package-path "$ROOT" resolve >/dev/null

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$DMG" "$OUT/"
# Sparkle picks up release notes from a file named like the archive.
"$ROOT/Scripts/release-notes.sh" "$TAG" > "$OUT/$(basename "${DMG%.*}").md"
[ -n "$PREVIOUS" ] && [ -f "$PREVIOUS" ] && cp "$PREVIOUS" "$OUT/appcast.xml"

ARGS=(--download-url-prefix "https://github.com/dflta/Swift-Exile/releases/download/$TAG/"
      --link "https://github.com/dflta/Swift-Exile"
      --full-release-notes-url "https://github.com/dflta/Swift-Exile/releases/tag/$TAG"
      --embed-release-notes
      --maximum-deltas 0)
if [ -n "${SPARKLE_ED25519_PRIVATE:-}" ]; then
  printf '%s' "$SPARKLE_ED25519_PRIVATE" | "$TOOLS/generate_appcast" --ed-key-file - "${ARGS[@]}" "$OUT"
else
  "$TOOLS/generate_appcast" --ed-key-file "$DIR/sparkle-ed25519-private.txt" "${ARGS[@]}" "$OUT"
fi
echo "$OUT/appcast.xml"
