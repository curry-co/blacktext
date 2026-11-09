#!/bin/bash
# Signs build/BlackText.app inside out: Sparkle's helpers, Sparkle, the blacktext command, then the app.
# Usage: scripts/sign-app.sh IDENTITY APP [--entitlements FILE]
# IDENTITY "-" signs ad hoc, for this Mac only. Any other identity gets the hardened runtime and a secure
# timestamp, which notarization requires.
set -euo pipefail

IDENTITY=$1
APP=$2
shift 2
if [ "$IDENTITY" = - ]; then
  options=(--force --sign -)
else
  options=(--force --options runtime --timestamp --sign "$IDENTITY")
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  # Not --deep: Sparkle's documentation asks for each part on its own.
  codesign "${options[@]}" "$SPARKLE/Versions/B/Autoupdate"
  codesign "${options[@]}" "$SPARKLE/Versions/B/Updater.app"
  codesign "${options[@]}" "$SPARKLE"
fi
codesign "${options[@]}" "$APP/Contents/Helpers/blacktext"
codesign "${options[@]}" "$@" "$APP"
