#!/bin/bash
# Builds build/BlackText.app from the Swift package. No Xcode needed.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/BlackTextCore/Version.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/BlackText.app

swift build -c release --product BlackTextApp
swift build -c release --product blacktext
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/BlackTextApp" "$APP/Contents/MacOS/BlackText"
cp "$BIN/blacktext" "$APP/Contents/Helpers/blacktext"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough to run on this Mac. Distribution would use a Developer ID.
codesign --force --sign - "$APP/Contents/Helpers/blacktext"
codesign --force --sign - "$APP"

echo "Built $APP ($VERSION, build $BUILD)"
