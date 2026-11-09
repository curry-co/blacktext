#!/bin/bash
# Builds build/BlackText.app from the Swift package. No Xcode needed.
# Set ARCHS="arm64 x86_64" for an app that runs on both Apple Silicon and Intel Macs;
# by default it builds only for this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/BlackTextCore/Version.swift)
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/BlackTextApp" "$APP/Contents/MacOS/BlackText"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/BlackText"
# Sparkle, for in-app updates (already universal). Its XPC services are only for sandboxed apps, and
# BlackText isn't sandboxed, so they're left out.
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
cp "$BIN/blacktext" "$APP/Contents/Helpers/blacktext"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/LICENSE-Sparkle"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough to run on this Mac. scripts/release.sh re-signs with a Developer ID.
scripts/sign-app.sh - "$APP"

echo "Built $APP ($VERSION, build $BUILD, $(lipo -archs "$APP/Contents/MacOS/BlackText"))"
