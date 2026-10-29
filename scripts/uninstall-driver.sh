#!/bin/bash
set -euo pipefail
if [ "${1:-}" != --confirm ]; then
    echo 'Removes only Local TTS Mic from /Library/Audio/Plug-Ins/HAL and restarts all system audio.'
    echo 'Close calls first. To proceed: ./scripts/uninstall-driver.sh --confirm'
    exit 1
fi
sudo /bin/rm -rf /Library/Audio/Plug-Ins/HAL/LocalSpeakMic.driver
sudo /usr/sbin/pkgutil --forget local.localspeak.mic.installer || true
sudo /usr/bin/killall coreaudiod || true
echo 'Local TTS Mic removed. App, models, voices, and preferences were retained.'
