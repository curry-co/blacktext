#!/bin/bash
# Installs build/BlackText.app into ~/Applications and links the blacktext command into ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$HOME/Applications"
mkdir -p "$DEST" "$HOME/.local/bin"

if pgrep -xq BlackText; then
  echo "Quitting the running BlackText…"
  osascript -e 'tell application id "co.curry.blacktext" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

rm -rf "$DEST/BlackText.app"
cp -R build/BlackText.app "$DEST/BlackText.app"
ln -sf "$DEST/BlackText.app/Contents/Helpers/blacktext" "$HOME/.local/bin/blacktext"

# Register the app (URL scheme, Services menu) with Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/BlackText.app"
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "Installed $DEST/BlackText.app"
echo "Linked ~/.local/bin/blacktext"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: add ~/.local/bin to your PATH to use the blacktext command." ;;
esac
echo
echo "Connect Claude Code:  claude mcp add blacktext -- \"$DEST/BlackText.app/Contents/Helpers/blacktext\" mcp"
