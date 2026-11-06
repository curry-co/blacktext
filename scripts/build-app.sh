#!/bin/bash
# Builds build/BlackText.app from the Swift package. No Xcode needed.
# Set ARCHS="arm64 x86_64" for an app that runs on both Apple Silicon and Intel Macs;
# by default it builds only for this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/BlackTextCore/Version.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/BlackText.app
ARCHS=${ARCHS:-}

if [ -z "$ARCHS" ]; then
  swift build -c release --product BlackTextApp
  swift build -c release --product blacktext
  BIN=$(swift build -c release --show-bin-path)
else
  # One build per architecture, joined into universal binaries.
  BIN=build/universal
  mkdir -p "$BIN"
  apps=() clis=()
  for arch in $ARCHS; do
    swift build -c release --arch "$arch" --product BlackTextApp
    swift build -c release --arch "$arch" --product blacktext
    archBin=$(swift build -c release --arch "$arch" --show-bin-path)
    apps+=("$archBin/BlackTextApp")
    clis+=("$archBin/blacktext")
  done
  lipo -create "${apps[@]}" -output "$BIN/BlackTextApp"
  lipo -create "${clis[@]}" -output "$BIN/blacktext"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/BlackTextApp" "$APP/Contents/MacOS/BlackText"
cp "$BIN/blacktext" "$APP/Contents/Helpers/blacktext"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough to run on this Mac. scripts/release.sh re-signs with a Developer ID.
codesign --force --sign - "$APP/Contents/Helpers/blacktext"
codesign --force --sign - "$APP"

echo "Built $APP ($VERSION, build $BUILD, $(lipo -archs "$APP/Contents/MacOS/BlackText"))"
