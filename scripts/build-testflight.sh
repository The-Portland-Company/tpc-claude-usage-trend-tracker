#!/usr/bin/env bash
# Archive the sandboxed Release-AppStore build, export a signed .pkg, and
# (with --upload) send it to App Store Connect / TestFlight using the ASC API key.
#
#   scripts/build-testflight.sh            # archive + export dist/ClaudeMeter-<ver>-<build>.pkg
#   scripts/build-testflight.sh --upload   # ...and upload to App Store Connect
#
# Prereqs (all present on this Mac as of 2026-09-03):
#   - "Apple Distribution" + "3rd Party Mac Developer Installer" certs in login keychain
#   - Provisioning profile "Claude Meter Mac App Store" (minted via ASC API, see scripts/asc.py)
#   - ASC API key ~/.appstoreconnect/private_keys/AuthKey_XG3FW9LT9Q.p8
#   - An app record for com.theportlandcompany.ClaudeMeter in App Store Connect (website only)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASE_SOURCE[0]:-${BASH_SOURCE[0]}}")/.." && pwd)"; cd "$ROOT"
UPLOAD=0; for a in "$@"; do [[ "$a" == "--upload" ]] && UPLOAD=1; done
KEY_ID=XG3FW9LT9Q; ISSUER=178bab61-1c45-4f62-9525-55f8ed15a98d
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
VER=$(grep MARKETING_VERSION project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep CURRENT_PROJECT_VERSION project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
ARCHIVE="build/ClaudeMeter-AppStore.xcarchive"; OUT="build/testflight-export"
echo "==> xcodegen generate"; xcodegen generate >/dev/null
echo "==> archive Release-AppStore $VER ($BUILD)"
xcodebuild -project ClaudeMeter.xcodeproj -scheme ClaudeMeter -configuration Release-AppStore \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive | grep -E "error|ARCHIVE" 
rm -rf "$OUT"
if [[ $UPLOAD == 1 ]]; then
  echo "==> export + upload to App Store Connect"
  sed 's#<string>export</string>#<string>upload</string>#' ExportOptions-testflight.plist > build/ExportOptions-upload.plist
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions-upload.plist \
    -exportPath "$OUT" -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
    | grep -E "error|Upload|EXPORT|succeeded" 
else
  echo "==> export .pkg"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions-testflight.plist -exportPath "$OUT" | grep -E "error|EXPORT"
  mkdir -p dist; cp "$OUT"/*.pkg "dist/ClaudeMeter-$VER-$BUILD.pkg"; ls -la dist/
fi
