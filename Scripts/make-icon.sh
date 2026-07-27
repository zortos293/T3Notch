#!/usr/bin/env bash
# Renders Resources/AppIcon.icns from Scripts/MakeAppIcon.swift.
# Run after changing the icon art; bundle.sh consumes the committed .icns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

ICONSET="$BUILD_DIR/AppIcon.iconset"
GENERATOR="$BUILD_DIR/MakeAppIcon"

echo "==> Compiling icon generator"
# NotchShape/NotchGeometry come from the app target so the icon uses the real
# panel silhouette rather than a copy that can drift.
swiftc -O -parse-as-library -swift-version 6 \
  Sources/T3Notch/NotchShape.swift \
  Sources/T3Notch/NotchGeometry.swift \
  Scripts/MakeAppIcon.swift \
  -o "$GENERATOR"

echo "==> Rendering icon sizes"
"$GENERATOR" "$ICONSET"

echo "==> Packing AppIcon.icns"
mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "==> Done: Resources/AppIcon.icns"
