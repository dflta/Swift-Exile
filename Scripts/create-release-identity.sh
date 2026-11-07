#!/bin/bash
# One-time setup: creates SwiftExile's release signing identity (plan §3.4).
#
#   - A self-signed code-signing certificate "SwiftExile Release". Every release is signed with it,
#     so macOS keeps users' Accessibility permission across updates (the app's designated
#     requirement names this certificate instead of a per-build hash).
#   - A Sparkle EdDSA (Ed25519) key pair. Updates are accepted only if signed with it.
#
# Everything is written OUTSIDE the repository, to $SWIFTEXILE_RELEASE_DIR (default
# ~/.swiftexile-release), readable only by you. BACK THIS FOLDER UP: losing the certificate resets
# every user's permissions on the next release, and losing the EdDSA key means installed copies
# can never auto-update again. For CI, upload the values as GitHub Actions secrets (see
# Documentation/releasing.md); never commit them.
set -euo pipefail

DIR="${SWIFTEXILE_RELEASE_DIR:-$HOME/.swiftexile-release}"
OPENSSL=/usr/bin/openssl   # LibreSSL: its .p12 files import cleanly into macOS keychains
NAME="SwiftExile Release"

if [ -e "$DIR/SwiftExile-Release.p12" ] || [ -e "$DIR/sparkle-ed25519-private.txt" ]; then
  echo "error: $DIR already has a release identity; refusing to overwrite it." >&2
  exit 1
fi

umask 077
mkdir -p "$DIR"
chmod 700 "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Code-signing certificate (20 years: an expiry would force a new certificate) ---
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = dflta
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -days 7300 -sha256 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
P12_PASSWORD="$("$OPENSSL" rand -base64 24)"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$DIR/SwiftExile-Release.p12" -passout "pass:$P12_PASSWORD"
printf '%s' "$P12_PASSWORD" > "$DIR/p12-password.txt"
# The certificate alone is public information (it's embedded in every signed build).
cp "$WORK/cert.pem" "$DIR/SwiftExile-Release-certificate.pem"

# --- Sparkle EdDSA key (raw 32-byte Ed25519 seed, base64, the format Sparkle's tools use) ---
swift - "$DIR" <<'SWIFT'
import CryptoKit
import Foundation
let dir = CommandLine.arguments[1]
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: dir + "/sparkle-ed25519-private.txt", atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(toFile: dir + "/sparkle-ed25519-public.txt", atomically: true, encoding: .utf8)
SWIFT

chmod 600 "$DIR"/*
echo "Created the release identity in $DIR:"
echo "  SwiftExile-Release.p12 + p12-password.txt   (secret: code-signing certificate and key)"
echo "  sparkle-ed25519-private.txt                 (secret: update signing key)"
echo "  sparkle-ed25519-public.txt                  (public: goes into Info.plist as SUPublicEDKey)"
echo "  SwiftExile-Release-certificate.pem          (public)"
echo
echo "Back up this folder now (e.g. to an encrypted disk or password manager)."
