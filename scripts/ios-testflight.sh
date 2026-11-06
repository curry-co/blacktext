#!/bin/bash
# Archives the iOS app, signs it automatically through the App Store Connect API key, and uploads it
# to TestFlight. Runs in GitHub Actions; needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (the .p8 text).
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_DIR=$(mktemp -d)
KEY="$KEY_DIR/AuthKey_$ASC_KEY_ID.p8"
trap 'rm -rf "$KEY_DIR"' EXIT
printf '%s\n' "$ASC_KEY_P8" > "$KEY"

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/BlackTextCore/Version.swift)
BUILD=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

xcodebuild archive -project iOS/BlackText.xcodeproj -scheme BlackText -configuration Release \
  -destination generic/platform=iOS -archivePath build/BlackText.xcarchive "${AUTH[@]}" \
  DEVELOPMENT_TEAM=AGX237Q865 CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" BT_CLOUD_SYNC=YES

xcodebuild -exportArchive -archivePath build/BlackText.xcarchive -exportOptionsPlist iOS/ExportOptions.plist \
  -exportPath build/export "${AUTH[@]}"

echo "Uploaded BlackText $VERSION ($BUILD) to TestFlight"
