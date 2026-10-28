#!/bin/bash
# Builds build/BlackText.app from the Swift package. No Xcode needed.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/BlktxtCore/Version.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/BlackText.app

swift build -c release --product BlktxtApp
swift build -c release --product blktxt
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/BlktxtApp" "$APP/Contents/MacOS/BlackText"
cp "$BIN/blktxt" "$APP/Contents/Helpers/blktxt"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough to run on this Mac. Distribution would use a Developer ID.
codesign --force --sign - "$APP/Contents/Helpers/blktxt"
codesign --force --sign - "$APP"

echo "Built $APP ($VERSION, build $BUILD)"
