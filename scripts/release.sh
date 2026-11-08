#!/bin/bash
# Builds build/BlackText.dmg for Apple Silicon and Intel Macs, signed with a Developer ID and notarized by Apple.
#
# Needs a "Developer ID Application" identity in the keychain and a notarytool keychain profile:
#   xcrun notarytool store-credentials blacktext-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>
# Override with SIGN_IDENTITY and NOTARY_PROFILE. Without an identity it still builds, ad-hoc signed and
# not notarized, which only opens on this Mac.
#
# iCloud sync needs a provisioning profile that grants Resources/BlackText.entitlements (PROFILE, by default
# ~/.config/blacktext-release/BlackText_Developer_ID.provisionprofile). Without one the app runs local-only.
# A development build that syncs with CloudKit's Development environment (to try schema changes):
#   SIGN_IDENTITY="Apple Development: …" PROFILE=…/BlackText_Mac_Development.provisionprofile \
#   CLOUD_ENV=Development NOTARY_PROFILE= scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}
NOTARY_PROFILE=${NOTARY_PROFILE-blacktext-notary}
PROFILE=${PROFILE:-$HOME/.config/blacktext-release/BlackText_Developer_ID.provisionprofile}
CLOUD_ENV=${CLOUD_ENV:-Production}
APP=build/BlackText.app
DMG=build/BlackText.dmg

ARCHS="arm64 x86_64" scripts/build-app.sh

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
}

# A release is signed, notarized and syncs, or it says plainly that it isn't: ALLOW_UNSIGNED=1 for a build
# that opens only on this Mac, ALLOW_NO_SYNC=1 for one without iCloud.
if [ -z "$IDENTITY" ]; then
  if [ "${ALLOW_UNSIGNED:-}" != 1 ]; then
    echo "No Developer ID identity in the keychain. Set ALLOW_UNSIGNED=1 for a build that opens only on this Mac." >&2
    exit 1
  fi
  echo "No Developer ID identity in the keychain: keeping the ad-hoc signature (opens only on this Mac)." >&2
else
  if [ ! -f "$PROFILE" ] && [ "${ALLOW_NO_SYNC:-}" != 1 ]; then
    echo "No provisioning profile at $PROFILE, so this build couldn't sync. Set ALLOW_NO_SYNC=1 to build it anyway." >&2
    exit 1
  fi
  echo "Signing with $IDENTITY"
  entitlements=()
  if [ -f "$PROFILE" ]; then
    # iCloud: embed the profile, grant the entitlements, and tell the app it may sync.
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    /usr/libexec/PlistBuddy -c "Add :BlackTextCloudSync bool true" "$APP/Contents/Info.plist"
    ENTITLEMENTS_FILE=$(mktemp -d)/BlackText.entitlements
    aps=$(echo "$CLOUD_ENV" | tr '[:upper:]' '[:lower:]')
    sed -e "s/<string>Production</<string>$CLOUD_ENV</" -e "s/<string>production</<string>$aps</" \
      Resources/BlackText.entitlements > "$ENTITLEMENTS_FILE"
    entitlements=(--entitlements "$ENTITLEMENTS_FILE")
    echo "iCloud sync on ($CLOUD_ENV)"
  else
    echo "No provisioning profile at $PROFILE: this build won't sync with iCloud." >&2
  fi
  # Inside out: the helper first, then the app. Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/blacktext"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" ${entitlements[@]+"${entitlements[@]}"} "$APP"
  codesign --verify --strict --deep "$APP"
  if [ -f "$PROFILE" ]; then
    # The signature has to carry the iCloud entitlements for the right CloudKit environment.
    granted=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
    for key in com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-container-environment; do
      grep -q "$key" <<<"$granted" || { echo "The signed app is missing $key." >&2; exit 1; }
    done
    grep -q "<string>$CLOUD_ENV</string>" <<<"$granted" || { echo "The signed app isn't set to CloudKit $CLOUD_ENV." >&2; exit 1; }
  fi

  if [ -n "$NOTARY_PROFILE" ]; then
    # Notarize and staple the app itself, so it carries its own ticket once it's out of the disk image.
    ZIP=$(mktemp -d)/BlackText.zip
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"
    spctl --assess --type execute "$APP"
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
