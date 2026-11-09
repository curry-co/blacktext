#!/bin/bash
# Writes site/appcast.xml, the feed the Mac app checks for updates (Sparkle), for the release just built
# by scripts/release.sh. The feed goes live when it's merged to main and the site deploys, so publish the
# GitHub release with the DMG first.
#
# Usage: scripts/appcast.sh [NOTES.html]
# NOTES.html is an HTML fragment shown in the update window; by default, a link to the release on GitHub.
# The DMG is signed with the update key: ~/.config/blacktext-release/sparkle-ed25519.key if it's there
# (KEY overrides), otherwise the "blacktext" key in the keychain. DOWNLOAD_URL and APPCAST override the
# download address and the output, for trying an update locally.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/BlackText.app
DMG=build/BlackText.dmg
NOTES=${1:-}
KEY=${KEY:-$HOME/.config/blacktext-release/sparkle-ed25519.key}
APPCAST=${APPCAST:-site/appcast.xml}
TOOLS=.build/artifacts/sparkle/Sparkle/bin

[ -f "$DMG" ] || { echo "No $DMG: run scripts/release.sh first." >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MINIMUM=$(plist LSMinimumSystemVersion)
plist SUFeedURL >/dev/null 2>&1 || { echo "$APP has no update feed; build it with scripts/release.sh." >&2; exit 1; }
DOWNLOAD_URL=${DOWNLOAD_URL:-https://github.com/curry-co/blacktext/releases/download/v$VERSION/BlackText.dmg}

if [ -f "$KEY" ]; then
  signature=$("$TOOLS/sign_update" --ed-key-file "$KEY" "$DMG")
else
  signature=$("$TOOLS/sign_update" --account blacktext "$DMG")
fi
# sign_update prints: sparkle:edSignature="…" length="…"
grep -qE '^sparkle:edSignature="[^"]+" length="[0-9]+"$' <<<"$signature" || { echo "sign_update failed." >&2; exit 1; }

if [ -n "$NOTES" ]; then
  notes=$(cat "$NOTES")
else
  notes="<p><a href=\"https://github.com/curry-co/blacktext/releases/tag/v$VERSION\">What's new in BlackText $VERSION</a></p>"
fi

# Only the newest release is listed: Sparkle offers the newest one the Mac can run.
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>BlackText</title>
    <link>https://curry-co.github.io/blacktext/</link>
    <description>Updates to BlackText for Mac.</description>
    <language>en</language>
    <item>
      <title>BlackText $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <description><![CDATA[$notes]]></description>
      <enclosure url="$DOWNLOAD_URL" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST"
echo "Wrote $APPCAST: BlackText $VERSION (build $BUILD)"
