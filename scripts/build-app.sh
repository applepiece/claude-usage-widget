#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION=Release
SIGN=auto
while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION=Debug; shift ;;
    --sign)
      if [ "$#" -lt 2 ]; then echo "Missing value for --sign" >&2; exit 2; fi
      SIGN="$2"; shift 2 ;;
    *) echo "Usage: scripts/build-app.sh [--debug] [--sign auto|adhoc|none]" >&2; exit 2 ;;
  esac
done
case "$SIGN" in
  auto) set -- ;;
  adhoc) set -- "CODE_SIGN_IDENTITY=-" "CODE_SIGN_STYLE=Manual" "DEVELOPMENT_TEAM=" ;;
  none) set -- "CODE_SIGNING_ALLOWED=NO" ;;
  *) echo "Invalid signing mode: $SIGN" >&2; exit 2 ;;
esac
xcodegen generate --quiet
xcodebuild -project "ClaudeUsage.xcodeproj" -scheme "ClaudeUsage" \
  -configuration "$CONFIGURATION" -derivedDataPath "$ROOT/.build/xcode" "$@" build
PRODUCT="$ROOT/.build/xcode/Build/Products/$CONFIGURATION/Claude Usage.app"
APP="$ROOT/dist/Claude Usage.app"
mkdir -p "$ROOT/dist"
# Preserve prior output instead of merging stale resources into the new bundle.
if [ -e "$APP" ]; then
  PREVIOUS="$(mktemp -d "$ROOT/.build/previous-app.XXXXXX")"
  mv "$APP" "$PREVIOUS/Claude Usage.app"
fi
ditto "$PRODUCT" "$APP"
PLIST="$APP/Contents/Info.plist"
echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
echo "Build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "Bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
if SIGNATURE="$(codesign -dv "$APP" 2>&1)"; then
  echo "$SIGNATURE" | sed -n '1p'
else
  echo "unsigned"
fi
