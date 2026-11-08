#!/bin/bash
# Installs a pinned XcodeGen, checked against the checksum GitHub publishes for it, and puts it on the
# PATH of later GitHub Actions steps. Update VERSION and SHA256 together.
set -euo pipefail

VERSION=2.46.0
SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
DIR=${RUNNER_TEMP:-$(mktemp -d)}/xcodegen-$VERSION

curl -fsSL -o "$DIR.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
echo "$SHA256  $DIR.zip" | shasum -a 256 -c -
rm -rf "$DIR"
mkdir -p "$DIR"
unzip -q "$DIR.zip" -d "$DIR"
BIN="$DIR/xcodegen/bin"
test -x "$BIN/xcodegen"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$BIN" >> "$GITHUB_PATH"; fi
"$BIN/xcodegen" --version
