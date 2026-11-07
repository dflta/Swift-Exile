#!/bin/bash
# Prints the CHANGELOG.md section for a version (the lines under "## <version>", up to the next
# "## " heading). Fails if there is none, so a release can't go out without its changelog.
#
# Usage: Scripts/release-notes.sh 1.2.3
set -euo pipefail

VERSION="${1#v}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTES="$(awk -v heading="## $VERSION" '
  $0 == heading { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$ROOT/CHANGELOG.md" | sed -e '/./,$!d')" # drop leading blank lines

if [ -z "${NOTES//[[:space:]]/}" ]; then
  echo "CHANGELOG.md has no section \"## $VERSION\"" >&2
  exit 1
fi
printf '%s\n' "$NOTES"
