#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"

CONFIG="${1:-release}"
# Releases set this so the bundle's version matches the tag.
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
PRODUCT_DIR="$ROOT/.build/$CONFIG"
APP_NAME="T3Notch"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
BINARY="$PRODUCT_DIR/${APP_NAME}"

echo "==> Building ${APP_NAME} (${CONFIG}) with ${DEVELOPER_DIR}"
swift build -c "$CONFIG" --arch arm64 --product "$APP_NAME"

if [[ ! -x "$BINARY" ]]; then
  # SwiftPM may nest the product under an arch triple on some toolchains.
  BINARY="$(find "$ROOT/.build" -type f -name "$APP_NAME" -path "*/${CONFIG}/*" | head -n 1)"
fi

if [[ ! -x "$BINARY" ]]; then
  echo "error: built binary not found" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  echo "warning: Resources/AppIcon.icns missing; run Scripts/make-icon.sh" >&2
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>T3Notch</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>gg.t3tools.t3notch</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>T3Notch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>__VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__BUILD_NUMBER__</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

# Substituted after the fact so the plist above stays a literal heredoc.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist" >/dev/null
echo "==> Version ${VERSION} (${BUILD_NUMBER})"

# T3 Connect consumes only public client configuration. These production
# defaults match T3 Code's packaged app; source-build environments may override
# all three for a different public Clerk/relay deployment.
CONNECT_CLERK_PUBLISHABLE_KEY="${T3CODE_CLERK_PUBLISHABLE_KEY:-pk_live_Y2xlcmsudDMuY29kZXMk}"
CONNECT_JWT_TEMPLATE="${T3CODE_CLERK_JWT_TEMPLATE:-t3-relay}"
CONNECT_RELAY_URL="${T3CODE_RELAY_URL:-https://relay.t3.codes}"

if [[ -n "$CONNECT_CLERK_PUBLISHABLE_KEY" \
   && -n "$CONNECT_JWT_TEMPLATE" \
   && -n "$CONNECT_RELAY_URL" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Add :T3ConnectClerkPublishableKey string $CONNECT_CLERK_PUBLISHABLE_KEY" \
    -c "Add :T3ConnectJWTTemplate string $CONNECT_JWT_TEMPLATE" \
    -c "Add :T3ConnectRelayURL string $CONNECT_RELAY_URL" \
    "$APP_DIR/Contents/Info.plist" >/dev/null
  echo "==> Embedded public T3 Connect configuration"
else
  echo "==> T3 Connect disabled (public configuration incomplete)"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "==> Ad-hoc codesign"
  codesign --force --deep --sign - "$APP_DIR"
else
  echo "==> Developer ID codesign (${SIGNING_IDENTITY})"
  # Notarization requires the hardened runtime and a trusted timestamp.
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$APP_DIR"
fi

echo "==> Done: ${APP_DIR}"
