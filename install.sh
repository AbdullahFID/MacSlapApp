#!/bin/bash
# Installs MacSlapApp from a release zip: ./install.sh
set -euo pipefail

APP_NAME="MacSlapApp"
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/$APP_NAME.app"

if [ ! -d "$SOURCE" ]; then
    echo "Couldn't find $APP_NAME.app next to this script ($HERE)." >&2
    exit 1
fi

if [ -w /Applications ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$APP_NAME.app"

echo "Installing $APP_NAME to $DEST_DIR..."

pkill -x "$APP_NAME" 2>/dev/null || true

# Clean up 2.x (SlapMacPro), which ran a bare binary from a LaunchAgent.
launchctl bootout "gui/$(id -u)/com.slapmacpro" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.slapmacpro.plist" "$HOME/Desktop/slapmac/bin/SlapMacPro"
pkill -x SlapMacPro 2>/dev/null || true

rm -rf "$DEST"
ditto "$SOURCE" "$DEST"

# Downloaded files are quarantined, and this build is ad-hoc signed rather
# than notarized, so Gatekeeper would otherwise refuse to open it.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

SOUNDS="$HOME/Library/Application Support/$APP_NAME/Sounds"
mkdir -p "$SOUNDS"

open "$DEST"

echo ""
echo "$APP_NAME is running — look for the hand in your menu bar."
echo "  App:        $DEST"
echo "  Sounds:     $SOUNDS"
echo "  Logs:       ~/Library/Logs/$APP_NAME/$APP_NAME.log"
echo ""
echo "It works right away with the built-in Robot Voice pack. Drop .mp3/.wav files"
echo "named like sexy_01.mp3 or punch_3.wav into the Sounds folder for the other packs."
echo ""
echo "To uninstall: quit it from the menu, then delete $DEST"
