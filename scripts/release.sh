#!/bin/bash
# Builds build/BlackText.dmg for Apple Silicon and Intel Macs, signed with a Developer ID and notarized by Apple.
#
# Needs a "Developer ID Application" identity in the keychain and a notarytool keychain profile:
#   xcrun notarytool store-credentials blacktext-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>
# Override with SIGN_IDENTITY and NOTARY_PROFILE. Without an identity it still builds, ad-hoc signed and
# not notarized, which only opens on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}
NOTARY_PROFILE=${NOTARY_PROFILE-blacktext-notary}
APP=build/BlackText.app
DMG=build/BlackText.dmg

ARCHS="arm64 x86_64" scripts/build-app.sh

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
}

if [ -z "$IDENTITY" ]; then
  echo "No Developer ID identity in the keychain: keeping the ad-hoc signature (opens only on this Mac)." >&2
else
  echo "Signing with $IDENTITY"
  # Inside out: the helper first, then the app. Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/blacktext"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --deep "$APP"

  if [ -n "$NOTARY_PROFILE" ]; then
    # Notarize and staple the app itself, so it carries its own ticket once it's out of the disk image.
    ZIP=$(mktemp -d)/BlackText.zip
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"
  fi
fi

# A plain disk image: the app and a shortcut to Applications. Nothing added.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname BlackText -srcfolder "$STAGE" -format ULFO -ov "$DMG" -quiet
rm -rf "$STAGE"

if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if [ -n "$NOTARY_PROFILE" ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
  fi
fi

(cd build && shasum -a 256 BlackText.dmg > BlackText.dmg.sha256)
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | xargs), sha256 $(cut -c1-12 build/BlackText.dmg.sha256)…)"
