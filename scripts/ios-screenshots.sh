#!/bin/bash
# Opens the iOS app in the Simulator with a few sample notes and saves screenshots of its main states,
# so changes can be checked without a phone. The app understands `-BTScreenshot <state>`.
# Usage: scripts/ios-screenshots.sh path/to/BlackText.app OUTPUT_DIR
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

# Sample notes, written by the Mac command-line tool into a database inside the app's container.
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
DB="$DATA/Library/Application Support/blacktext/blacktext.sqlite"
mkdir -p "$(dirname "$DB")"
export BLACKTEXT_DB="$DB"
printf 'Groceries\n\nCoffee beans, dark roast\nOat milk\nBread' | "$CLI" new >/dev/null
printf 'https://github.com/curry-co/blacktext' | "$CLI" new >/dev/null
printf 'Notes on pricing\n\nThanks for sending this over. I read it twice and I think the second paragraph is doing all the work, so I would lead with it. The rest can follow in any order.\n\nThe obstacle is the way.' | "$CLI" new >/dev/null

shoot() { # name, appearance, launch arguments…
  local name=$1 appearance=$2
  shift 2
  xcrun simctl ui "$DEVICE" appearance "$appearance"
  SIMCTL_CHILD_BLACKTEXT_DB="$DB" xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE" "$@" >/dev/null
  sleep 4
  xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null
  echo "Saved $name.png"
}

shoot canvas-light light
shoot sidebar-light light -BTScreenshot sidebar
shoot find-light light -BTScreenshot find
shoot canvas-dark dark
shoot sidebar-dark dark -BTScreenshot sidebar
xcrun simctl terminate "$DEVICE" "$BUNDLE" || true
