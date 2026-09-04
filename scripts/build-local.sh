#!/usr/bin/env bash
# Build Claude Meter locally (Release, Apple Development signing) and install it
# to /Applications.
#
#   scripts/build-local.sh              # build + install + relaunch
#   scripts/build-local.sh --no-install # build only
#
# Signing note: this Mac has no "Developer ID Application" certificate, so the
# build signs manually with the "Apple Development" certificate. The app is not
# sandboxed (it reads Claude Code's Keychain item); hardened runtime is on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

SCHEME="ClaudeMeter"
CONFIG="Release"
DERIVED="$ROOT/build/DerivedData"
INSTALL_PATH="/Applications/Claude Meter.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development}"
ENTITLEMENTS="${ENTITLEMENTS:-Sources/ClaudeMeter.entitlements}"

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild ($CONFIG, identity: $SIGNING_IDENTITY)"
xcodebuild \
  -project ClaudeMeter.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  DEVELOPMENT_TEAM=VP38993WK6 \
  build

APP="$(/usr/bin/find "$DERIVED/Build/Products/$CONFIG" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "${APP:-}" || ! -d "$APP" ]]; then
  echo "ERROR: no .app produced under $DERIVED/Build/Products/$CONFIG" >&2
  exit 1
fi

echo "==> codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | sed -n '1,10p'

if [[ "$INSTALL" -eq 1 ]]; then
  echo "==> installing to $INSTALL_PATH"
  ditto "$APP" "$INSTALL_PATH"
  echo "==> relaunching"
  pkill -x "Claude Meter" || true
  sleep 1
  open "$INSTALL_PATH"
  sleep 1
  PID="$(pgrep -x "Claude Meter" || true)"
  echo "Installed: $INSTALL_PATH (pid ${PID:-unknown})"
else
  echo "Built (not installed): $APP"
fi
