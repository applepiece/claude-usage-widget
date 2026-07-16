#!/bin/bash
# Claude Usage Widget — uninstaller
set -uo pipefail

echo "==> Removing Claude Usage Widget"
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
pkill -f "claude-usage-widget/server.py" 2>/dev/null || true
lsof -ti :8737 | xargs kill 2>/dev/null || true
rm -rf "/Applications/Claude Usage.app"
echo "==> App removed (its Login Items entry disappears with it)."
echo "    Server files in ~/claude-usage-widget were kept; delete that folder"
echo "    yourself if you no longer want them."
