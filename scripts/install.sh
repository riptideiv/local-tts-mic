#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/build/Local TTS Mic.app"
DESTINATION="$HOME/Applications/Local TTS Mic.app"
if [ ! -x "$SOURCE/Contents/MacOS/LocalSpeak" ]; then
    ./scripts/build.sh
fi
if [ -e "$DESTINATION" ]; then
    IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)
    if [ "$IDENTIFIER" != local.localspeak.app ]; then
        echo "A different app already exists at $DESTINATION. Choose another destination."
        exit 1
    fi
fi
mkdir -p "$HOME/Applications"
ditto "$SOURCE" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
echo "Installed $DESTINATION"
if [ "${1:-}" != --no-open ]; then open "$DESTINATION"; fi
