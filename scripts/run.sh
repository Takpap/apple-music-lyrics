#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Building AppleMusicLyrics…"
swift build -c release

BIN="$ROOT/.build/release/AppleMusicLyrics"
echo "→ Launching $BIN"
echo "  First run: allow Automation access for Music when prompted."
echo "  Quit from the menu bar item, or: pkill -f AppleMusicLyrics"
exec "$BIN"
