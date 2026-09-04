#!/usr/bin/env bash
# Archive and package Claude Meter as a DMG.
#
#   scripts/build-release.sh
#   SIGNING_IDENTITY="Developer ID Application" scripts/build-release.sh
#
# With a "Developer ID" identity the archive is exported through
# ExportOptions-developer-id.plist, notarized and stapled. With anything else
# (default "Apple Development") the app is taken straight out of the archive,
# notarization is skipped, and the DMG only installs on Macs that already trust
# that development certificate. See docs/release.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="ClaudeMeter"
CONFIG="Release"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development}"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-meter-notary}"
ENTITLEMENTS="${ENTITLEMENTS:-Sources/ClaudeMeter.entitlements}"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/ClaudeMeter.xcarchive"
EXPORT_DIR="$BUILD/export"
DIST="$ROOT/dist"

echo "==> xcodegen generate"
xcodegen generate

VERSION="$(/usr/bin/awk '/MARKETING_VERSION:/ { gsub(/"/,"",$2); print $2; exit }' project.yml)"
VERSION="${VERSION:-0.0.0}"

if [[ "$SIGNING_IDENTITY" == Developer\ ID* ]]; then
  NOTARIZE=1
else
  NOTARIZE=0
fi

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD" "$DIST"

echo "==> xcodebuild archive (identity: $SIGNING_IDENTITY, version: $VERSION)"
xcodebuild \
  -project ClaudeMeter.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  DEVELOPMENT_TEAM=VP38993WK6 \
  archive

if [[ "$NOTARIZE" -eq 1 ]]; then
  echo "==> xcodebuild -exportArchive (developer-id)"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$ROOT/ExportOptions-developer-id.plist"
else
  # exportArchive would demand a provisioning profile we cannot mint; the
  # archived app is already signed with the identity above, so use it directly.
  echo "==> copying app out of the archive (no export step)"
  mkdir -p "$EXPORT_DIR"
  ditto "$ARCHIVE/Products/Applications/" "$EXPORT_DIR/"
fi

APP="$(/usr/bin/find "$EXPORT_DIR" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "${APP:-}" || ! -d "$APP" ]]; then
  echo "ERROR: no .app in $EXPORT_DIR" >&2
  exit 1
fi

echo "==> codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$NOTARIZE" -eq 1 ]]; then
  ZIP="$BUILD/notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> notarytool submit (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> stapler staple"
  xcrun stapler staple "$APP"
else
  echo
  echo "WARNING: signed with '$SIGNING_IDENTITY', not a Developer ID certificate."
  echo "WARNING: this DMG is NOT notarized. It will only install on Macs that"
  echo "WARNING: already trust this development certificate (i.e. this one)."
  echo "WARNING: See docs/release.md for the one-time Developer ID setup."
  echo
fi

DMG="$DIST/ClaudeMeter-$VERSION.dmg"
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE"
rm -f "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create"
hdiutil create -volname "Claude Meter $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo
echo "DMG: $DMG"
codesign -dv --verbose=2 "$APP" 2>&1 | sed -n '1,10p'
