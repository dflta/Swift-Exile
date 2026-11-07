#!/bin/bash
# Runs build/SwiftExile.app with focus and geometry tracing, writing a timestamped log.
# By default it uses a COPY of your Exiled Exchange 2 settings, so a test session never
# changes the real file. Pass --real-settings to use the real one (quit the Electron app first).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SwiftExile.app"
REAL_DATA="$HOME/Library/Application Support/exiled-exchange-2/apt-data"
LOG_DIR="$HOME/Library/Logs/SwiftExile"
LOG="$LOG_DIR/diagnostics-$(date +%Y%m%d-%H%M%S).log"

if [ ! -x "$APP/Contents/MacOS/SwiftExile" ]; then
  echo "App not built yet: run Scripts/bundle-app.sh first" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
if [ "${1:-}" = "--real-settings" ]; then
  DATA_DIR="$REAL_DATA"
  echo "Using your real settings: $DATA_DIR"
else
  DATA_DIR="$(mktemp -d)/apt-data"
  mkdir -p "$DATA_DIR"
  [ -f "$REAL_DATA/config.json" ] && cp "$REAL_DATA/config.json" "$DATA_DIR/config.json"
  echo "Using a copy of your settings: $DATA_DIR"
fi

echo "Logging to $LOG"
echo "Quit SwiftExile from its menu bar item (or press Ctrl+C here) to finish."
SWIFTEXILE_TRACE_FOCUS=1 SWIFTEXILE_DATA_DIR="$DATA_DIR" \
  "$APP/Contents/MacOS/SwiftExile" 2>&1 | tee "$LOG"
