#!/bin/bash
# Opens the iOS app in the Simulator with a few sample notes and saves screenshots of its main states,
# so changes can be checked without a phone. The app understands `-BTScreenshot <state>`.
# Usage: scripts/ios-screenshots.sh path/to/BlackText.app OUTPUT_DIR
# SIMULATOR picks the device, by name or id. On a 6.9-inch iPhone or a 13-inch iPad, the screenshots are the
# sizes the App Store asks for, with the status bar at 9:41 and full.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=$1
OUT=$2
DEVICE=${SIMULATOR:-iPhone 17}
BUNDLE=co.curry.blacktext
mkdir -p "$OUT"

swift build -c release --product blacktext
CLI="$(swift build -c release --show-bin-path)/blacktext"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
# The first time the keyboard appears on an iPhone, a "slide to type" tip covers it. Mark the tip as seen.
xcrun simctl spawn "$DEVICE" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true

# Sample notes, written by the Mac command-line tool into a database inside the app's container.
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
DB="$DATA/Library/Application Support/blacktext/blacktext.sqlite"
mkdir -p "$(dirname "$DB")"
export BLACKTEXT_DB="$DB"
# Oldest first: the last one is the newest, and opens on the page.
printf 'Book list\n\nPiranesi\nThe Remains of the Day\nA Gentleman in Moscow\nThe Overstory' | "$CLI" new >/dev/null
printf 'Groceries\n\nCoffee beans, dark roast\nOat milk\nSourdough\nLemons' | "$CLI" new >/dev/null
printf 'https://github.com/curry-co/blacktext' | "$CLI" new >/dev/null
printf 'Gift ideas\n\nDad: a good thermos\nSam: watercolors\nMaya: the next book in the series' | "$CLI" new >/dev/null
printf "Reply to Alex\n\nThanks for sending this over. I read it twice, and I think the second paragraph is doing all the work, so I'd lead with it. The rest can follow in any order.\n\nTalk Thursday?" | "$CLI" new >/dev/null
printf "Morning pages\n\nThe point isn't to write well. It's to get it down before the thought is gone: an idea, a quote, a link, the paragraph you want to rewrite later.\n\nOne page. Plain text. Nothing added.\n\nWhen it's done, file it away and start a clean page. It's still in the sidebar, with every version kept." | "$CLI" new >/dev/null

# The status bar Apple uses in its own screenshots.
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName '' 2>/dev/null || true

shoot() { # name, appearance, launch arguments…
  local name=$1 appearance=$2
  shift 2
  xcrun simctl ui "$DEVICE" appearance "$appearance"
  SIMCTL_CHILD_BLACKTEXT_DB="$DB" xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE" "$@" >/dev/null
  sleep 7 # CI's Simulator sometimes needs more than 4 seconds to draw the first frame
  xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null
  echo "Saved $name.png"
}

# Open the page once without keeping the screenshot, so that if the tip shows anyway, it's used up here.
shoot warm-up light -BTScreenshot canvas
rm "$OUT/warm-up.png"
shoot canvas-light light -BTScreenshot canvas
shoot sidebar-light light -BTScreenshot sidebar
shoot find-light light -BTScreenshot find
shoot canvas-dark dark -BTScreenshot canvas
shoot sidebar-dark dark -BTScreenshot sidebar
xcrun simctl terminate "$DEVICE" "$BUNDLE" || true
xcrun simctl status_bar "$DEVICE" clear 2>/dev/null || true
sips -g pixelWidth -g pixelHeight "$OUT/canvas-light.png" | awk '/pixel/ {printf "%s ", $2} END {print "pixels"}'
