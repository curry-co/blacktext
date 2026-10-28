#!/bin/bash
# Installs build/BlackText.app into ~/Applications and links the blktxt command into ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$HOME/Applications"
mkdir -p "$DEST" "$HOME/.local/bin"

if pgrep -xq BlackText; then
  echo "Quitting the running BlackText…"
  osascript -e 'tell application id "co.curry.blktxt" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

rm -rf "$DEST/blktxt.app" "$DEST/BlackText.app"
cp -R build/BlackText.app "$DEST/BlackText.app"
ln -sf "$DEST/BlackText.app/Contents/Helpers/blktxt" "$HOME/.local/bin/blktxt"

# Register the app (URL scheme, Services menu) with Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/BlackText.app"
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "Installed $DEST/BlackText.app"
echo "Linked ~/.local/bin/blktxt"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: add ~/.local/bin to your PATH to use the blktxt command." ;;
esac
echo
echo "Connect Claude Code:  claude mcp add blktxt -- \"$DEST/BlackText.app/Contents/Helpers/blktxt\" mcp"
