#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x 'build/Local TTS Mic.app/Contents/MacOS/LocalSpeak' ]; then
    ./scripts/build.sh
fi
open 'build/Local TTS Mic.app'

