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
# Item and stat lookup indexes (public/data/<lang>/*.index.bin). They aren't in git; upstream CI
# generates them before building (.github/workflows/main.yml). Without them every item lookup
# fails and the price check shows "An error occurred while parsing the item".
npm run make-index-files --silent
# `npm run build` also runs vue-tsc type checking; upstream CI covers that, so call Vite directly.
npx vite build --logLevel warn
# Headless price-check engine (Engine/engine.ts) built from the same upstream sources.
npx vite build --config "$ROOT/Engine/vite.config.mjs"
echo "engine built: $ROOT/Engine/dist/engine.js"
for lang in public/data/*/; do
  if [ -f "$lang/items.ndjson" ] && [ ! -f "$lang/items-ref.index.bin" ]; then
    echo "missing index files in $lang" >&2
    exit 1
  fi
done
echo "renderer built: $RENDERER/dist"
