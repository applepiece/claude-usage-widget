#!/bin/bash
# Claude Usage Widget · installer
# Builds the native app from source and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Claude Usage Widget installer"

# --- requirements ---------------------------------------------------------
if ! xcodebuild -version >/dev/null 2>&1 || ! command -v xcodegen >/dev/null 2>&1; then
  echo "!! Xcode and xcodegen are required to build."
  exit 1
fi
if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  # a warning, not a failure: the widget now renders a signed-out state and its
  # menu can start the login itself, so refusing to install here would strand a
  # signed-out Mac with no way to install the thing that signs it back in
  echo "!! No Claude Code credentials in the Keychain: installing anyway."
  echo "   The widget will show \"Not signed in\"; use its menu > Sign In to Claude."
fi

# --- build the app bundle --------------------------------------------------
APP="/Applications/Claude Usage.app"
bash scripts/build-app.sh
echo "==> ~/Library/Application Support/claude-usage-widget is no longer used; its files are kept."

# --- launch ----------------------------------------------------------------
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
# Kill the old server by the port it holds, not by a path pattern: one started
# with a relative path shows up in ps as plain "server.py", so pkill -f missed
# it and the previous build kept serving 8737 through every reinstall.
SRV_PID="$(lsof -nP -tiTCP:8737 -sTCP:LISTEN 2>/dev/null | head -1 || true)"
if [ -n "${SRV_PID:-}" ] && ps -p "$SRV_PID" -o args= 2>/dev/null | grep -q "server\.py"; then
  kill "$SRV_PID" 2>/dev/null || true
fi
sleep 1
rm -rf "$APP"
ditto "dist/Claude Usage.app" "$APP"
open "$APP"
echo "==> Done! Claw'd is floating on your screen 🦀"
echo "    • drag to move · right-click for Refresh / Quit"
echo "    • auto-starts at login (System Settings › Login Items)"
