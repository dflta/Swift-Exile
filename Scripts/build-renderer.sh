#!/bin/bash
# Builds the upstream Exiled Exchange 2 renderer (Vue + Vite) into upstream/renderer/dist.
# Node is only needed at build time; nothing from node_modules ships in the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDERER="$ROOT/upstream/renderer"

if [ ! -f "$RENDERER/package.json" ]; then
  echo "upstream submodule missing: run 'git submodule update --init'" >&2
  exit 1
fi

cd "$RENDERER"
# Reinstall only when the lockfile changed since the last install.
if [ ! -d node_modules ] || [ package-lock.json -nt node_modules/.package-lock.json ]; then
  npm ci --no-audit --no-fund
fi
# `npm run build` also runs vue-tsc type checking; upstream CI covers that, so call Vite directly.
npx vite build --logLevel warn
echo "renderer built: $RENDERER/dist"
