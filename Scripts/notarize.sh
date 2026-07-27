#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"

APP_NAME="T3Notch"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-t3notch-notary}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: ${APP_DIR} does not exist; run Scripts/bundle.sh first" >&2
  exit 1
fi

SIGNATURE_DETAILS=$(codesign -dvvv "$APP_DIR" 2>&1)

if ! grep -q '^Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"; then
  echo "error: ${APP_DIR} is not signed with a Developer ID Application certificate" >&2
  exit 1
fi

if ! grep -q '^Runtime Version=' <<<"$SIGNATURE_DETAILS"; then
  echo "error: ${APP_DIR} was not signed with the hardened runtime" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
SUBMISSION_ZIP="$ROOT/dist/.${APP_NAME}-${VERSION}-notarization.zip"
FINAL_ZIP="$ROOT/dist/${APP_NAME}-${VERSION}-arm64.zip"

echo "==> Verifying Developer ID signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Packaging notarization submission"
ditto -c -k --keepParent "$APP_DIR" "$SUBMISSION_ZIP"

echo "==> Submitting to Apple notarization service"
xcrun notarytool submit "$SUBMISSION_ZIP" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

echo "==> Packaging final stapled build"
ditto -c -k --keepParent "$APP_DIR" "$FINAL_ZIP"

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose=2 "$APP_DIR"

echo "==> Done: ${FINAL_ZIP}"
shasum -a 256 "$FINAL_ZIP"
