#!/bin/bash
# Installs build/BlackText.app into ~/Applications and links the blacktext command into ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$HOME/Applications"
mkdir -p "$DEST" "$HOME/.local/bin"

APP="$DEST/BlackText.app"
NEW="$DEST/.BlackText.app.new"
OLD="$DEST/.BlackText.app.old"
LINK="$HOME/.local/bin/blacktext"
CLI="$APP/Contents/Helpers/blacktext"

# Something else called blacktext in ~/.local/bin isn't ours to replace.
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "$LINK exists and isn't a link to BlackText; leaving it alone. Move it aside and run this again." >&2
  exit 1
fi

# Copy and check the new app before touching the old one.
rm -rf "$NEW"
cp -R build/BlackText.app "$NEW"
codesign --verify --strict "$NEW"

if pgrep -xq BlackText; then
  echo "Quitting the running BlackText…"
  osascript -e 'tell application id "co.curry.blacktext" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 50); do pgrep -xq BlackText || break; sleep 0.2; done
  if pgrep -xq BlackText; then
    rm -rf "$NEW"
    echo "BlackText is still running (it may be asking about unsaved changes). Quit it and run this again." >&2
    exit 1
  fi
fi

# Swap, keeping the old app until the new one is in place.
rm -rf "$OLD"
if [ -e "$APP" ]; then mv "$APP" "$OLD"; fi
if ! mv "$NEW" "$APP"; then
  if [ -e "$OLD" ]; then mv "$OLD" "$APP"; fi
  echo "Couldn't put the new BlackText in place; the old one is back." >&2
  exit 1
fi
rm -rf "$OLD"
ln -sfn "$CLI" "$LINK"

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
