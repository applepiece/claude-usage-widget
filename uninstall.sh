#!/bin/bash
# Claude Usage Widget · uninstaller
set -uo pipefail

echo "==> Removing Claude Usage Widget"
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
# Match the bundled server and older installations without stopping unrelated services.
SRV_PID="$(lsof -nP -tiTCP:8737 -sTCP:LISTEN 2>/dev/null | head -1 || true)"
if [ -n "${SRV_PID:-}" ] && ps -p "$SRV_PID" -o args= 2>/dev/null | grep -q "server\.py"; then
  kill "$SRV_PID" 2>/dev/null || true
fi
rm -rf "/Applications/Claude Usage.app"
echo "==> App removed (its Login Items entry disappears with it)."
echo "    Server files in ~/Library/Application Support/claude-usage-widget were kept; delete that folder"
echo "    yourself if you no longer want them."
