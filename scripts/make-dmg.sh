#!/bin/bash
# Package an existing app. This does not sign, notarize, or launch anything.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 2 ]; then
  echo "Usage: scripts/make-dmg.sh <app> <out.dmg>" >&2
  exit 1
fi
if [ ! -d "$1" ] || [ ! -f "$1/Contents/Info.plist" ]; then
  echo "App bundle not found: $1" >&2
  exit 1
fi
APP_DIR="$(cd "$(dirname "$1")" && pwd)"
APP_NAME="$(basename "$1")"
APP="$APP_DIR/$APP_NAME"
case "$APP_NAME" in *.app) ;; *) echo "Input must be an .app bundle." >&2; exit 1 ;; esac
case "$2" in *.dmg) ;; *) echo "Output must end in .dmg." >&2; exit 1 ;; esac
mkdir -p "$(dirname "$2")"
OUTPUT_DIR="$(cd "$(dirname "$2")" && pwd)"
OUTPUT="$OUTPUT_DIR/$(basename "$2")"
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  echo "Output already exists. Choose another filename: $OUTPUT" >&2
  exit 1
fi
mkdir -p "$ROOT/.build/release"
# Retain staging for inspection instead of deleting files.
STAGING="$(mktemp -d "$ROOT/.build/release/dmg-staging.XXXXXX")"
printf '==> Stage app and Applications link: %s\n' "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME"
ln -s "/Applications" "$STAGING/Applications"
printf '==> Create UDZO image: %s\n' "$OUTPUT"
hdiutil create -volname "Claude Usage" -srcfolder "$STAGING" -format UDZO "$OUTPUT"
