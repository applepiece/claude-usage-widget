#!/bin/bash
# Claude Usage Widget — installer
# Builds the native app from source and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Claude Usage Widget installer"

# --- requirements ---------------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "!! Xcode Command Line Tools are required to build."
  echo "   Run:  xcode-select --install   then re-run this script."
  exit 1
fi
if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  echo "!! No Claude Code credentials found in the Keychain."
  echo "   Log in to Claude Code first (run \`claude\` in a terminal), then re-run."
  exit 1
fi

# --- server files → ~/claude-usage-widget ---------------------------------
DEST="$HOME/claude-usage-widget"
if [ "$(pwd -P)" != "$(cd "$DEST" 2>/dev/null && pwd -P)" ]; then
  echo "==> Installing server to $DEST"
  mkdir -p "$DEST/app/fonts"
  cp server.py "$DEST/"
  cp app/fonts/PressStart2P-Regular.ttf "$DEST/app/fonts/"
fi

# --- build the app bundle --------------------------------------------------
APP="/Applications/Claude Usage.app"
echo "==> Building $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.heng.claude-usage-widget</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
swiftc -O -o "$APP/Contents/MacOS/ClaudeUsage" app/WidgetView.swift app/main.swift
cp app/fonts/PressStart2P-Regular.ttf "$APP/Contents/Resources/Fonts/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
codesign --force -s - "$APP"

# --- launch ----------------------------------------------------------------
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
sleep 0.5
open "$APP"
echo "==> Done! Claw'd is floating on your screen 🦀"
echo "    • drag to move · right-click for Refresh / Quit"
echo "    • auto-starts at login (System Settings › Login Items)"
