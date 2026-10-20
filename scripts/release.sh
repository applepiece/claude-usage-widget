#!/bin/bash
# Developer ID distribution. Run on a Mac outside the sandbox.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-usage-notary}"
SKIP_NOTARIZE=false
usage () {
  echo "Usage: scripts/release.sh [--notary-profile NAME] [--skip-notarize]"
}
step () { printf '==> %s\n' "$*"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --notary-profile)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        usage >&2; exit 1
      fi
      NOTARY_PROFILE="$2"; shift 2 ;;
    --skip-notarize) SKIP_NOTARIZE=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

# Read the project without generating it or invoking Xcode.
TEAM_ID="$(awk '/^[[:space:]]*DEVELOPMENT_TEAM:/ {
  value = $2; gsub(/[\047\042]/, "", value); print value; exit
}' "$ROOT/project.yml")"
if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Cannot read a ten-character DEVELOPMENT_TEAM from project.yml." >&2
  exit 1
fi
step "Check Developer ID Application certificate for team $TEAM_ID"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -v team="$TEAM_ID" '
  index($0, "\042Developer ID Application:") && index($0, "(" team ")\042") {
    print $2; exit
  }')"
if [ -z "$IDENTITY" ]; then
  printf 'Missing: a valid Developer ID Application certificate and private key for team %s.\n' "$TEAM_ID" >&2
  echo "1. Join the Apple Developer Program (paid membership, USD 99/year). A free Personal Team cannot release this app." >&2
  echo "2. Create a Developer ID Application certificate at developer.apple.com > Certificates or Xcode > Settings > Accounts, and install its private key on this Mac." >&2
  echo "3. Rerun scripts/release.sh." >&2
  exit 2
fi

if [ "$SKIP_NOTARIZE" = false ]; then
  step "Check notarytool keychain profile $NOTARY_PROFILE"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    printf 'Missing or unusable notarytool keychain profile: %s\n' "$NOTARY_PROFILE" >&2
    echo "Run this once, replacing <email> with your Apple ID. Enter an app-specific password at the interactive prompt:" >&2
    printf '  xcrun notarytool store-credentials %q --apple-id <email> --team-id %s\n' "$NOTARY_PROFILE" "$TEAM_ID" >&2
    exit 3
  fi
fi
for tool in xcodegen xcodebuild xcrun codesign ditto hdiutil spctl shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing tool: %s. Install Xcode 27 and XcodeGen before releasing.\n' "$tool" >&2
    exit 1
  fi
done
EXPORT_OPTIONS="$ROOT/Config/ExportOptions-DeveloperID.plist"
EXPORT_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$EXPORT_OPTIONS")"
if [ "$EXPORT_TEAM" != "$TEAM_ID" ]; then
  echo "Set teamID in Config/ExportOptions-DeveloperID.plist to $TEAM_ID before releasing." >&2
  exit 1
fi

RELEASE_DIR="$ROOT/.build/release"
ARCHIVE="$RELEASE_DIR/ClaudeUsage.xcarchive"
EXPORT_DIR="$RELEASE_DIR/export"
mkdir -p "$RELEASE_DIR" "$ROOT/dist"
# Preserve previous products. Xcode must receive fresh archive/export paths.
if [ -e "$ARCHIVE" ] || [ -e "$EXPORT_DIR" ]; then
  PREVIOUS="$(mktemp -d "$RELEASE_DIR/previous.XXXXXX")"
  if [ -e "$ARCHIVE" ]; then mv "$ARCHIVE" "$PREVIOUS/ClaudeUsage.xcarchive"; fi
  if [ -e "$EXPORT_DIR" ]; then mv "$EXPORT_DIR" "$PREVIOUS/export"; fi
fi
trap 'result=$?; printf "Release failed (exit %s). Logs: %s\n" "$result" "$RELEASE_DIR" >&2; exit "$result"' ERR

step "Generate ClaudeUsage.xcodeproj"
xcodegen generate >"$RELEASE_DIR/generate.log" 2>&1
step "Archive Release with Developer ID Application"
xcodebuild archive CODE_SIGN_IDENTITY="Developer ID Application" \
  "DEVELOPMENT_TEAM=$TEAM_ID" CODE_SIGN_STYLE=Manual \
  -project "$ROOT/ClaudeUsage.xcodeproj" -scheme "ClaudeUsage" \
  -configuration "Release" -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" -derivedDataPath "$ROOT/.build/xcode" \
  >"$RELEASE_DIR/archive.log" 2>&1
step "Export Developer ID app"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" -exportPath "$EXPORT_DIR" \
  >"$RELEASE_DIR/export.log" 2>&1
APP="$EXPORT_DIR/Claude Usage.app"
step "Verify exported signature and hardened runtime"
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
printf '%s\n' "$SIGNATURE" >"$RELEASE_DIR/signature.log"
if ! printf '%s\n' "$SIGNATURE" | grep -q '^Authority=Developer ID Application:' \
  || ! printf '%s\n' "$SIGNATURE" | grep -Eq 'flags=.*[(,]runtime[,)]' \
  || ! printf '%s\n' "$SIGNATURE" | grep -qx "TeamIdentifier=$TEAM_ID"; then
  echo "Export must have a Developer ID Application signature, the expected team, and the hardened runtime flag. See signature.log." >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "Built CFBundleShortVersionString is missing or unsafe for a release filename: $VERSION" >&2
  exit 1
fi
ZIP="$RELEASE_DIR/Claude-Usage-$VERSION.zip"
DMG="$ROOT/dist/Claude-Usage-$VERSION.dmg"
# Keep earlier artifacts, including a prior ZIP whose app ticket may differ.
if [ -e "$ZIP" ] || [ -e "$DMG" ] || [ -e "$DMG.sha256" ]; then
  PREVIOUS="$(mktemp -d "$RELEASE_DIR/previous-artifacts.XXXXXX")"
  for artifact in "$ZIP" "$DMG" "$DMG.sha256"; do
    if [ -e "$artifact" ]; then mv "$artifact" "$PREVIOUS/"; fi
  done
fi

if [ "$SKIP_NOTARIZE" = false ]; then
  step "ZIP app for notarization"
  ditto -c -k --keepParent "$APP" "$ZIP"
  step "Notarize app and wait for acceptance"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format plist >"$RELEASE_DIR/app-notary.plist"
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$RELEASE_DIR/app-notary.plist")" != "Accepted" ]; then
    echo "App notarization was not accepted. See .build/release/app-notary.plist; use its id with notarytool log." >&2
    exit 1
  fi
  step "Staple and validate app ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi
step "Package DMG for version $VERSION"
bash "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG"
step "Sign DMG with Developer ID Application"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
if [ "$SKIP_NOTARIZE" = false ]; then
  step "Notarize DMG and wait for acceptance"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format plist >"$RELEASE_DIR/dmg-notary.plist"
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$RELEASE_DIR/dmg-notary.plist")" != "Accepted" ]; then
    echo "DMG notarization was not accepted. See .build/release/dmg-notary.plist; use its id with notarytool log." >&2
    exit 1
  fi
  step "Staple and validate DMG ticket"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  step "Assess DMG and app with Gatekeeper"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  spctl -a -vv "$APP"
else
  step "Local test only: notarization, stapling, and Gatekeeper assessments skipped"
fi
step "Write SHA-256 checksum"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$DMG")" >"$DMG.sha256")
if [ "$SKIP_NOTARIZE" = false ]; then
  step "Ready: notarized and stapled $DMG"
else
  step "Ready for local testing only: $DMG"
fi
