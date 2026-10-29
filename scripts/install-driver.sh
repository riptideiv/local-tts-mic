#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -f 'build/Local TTS Mic Driver.pkg' ]; then ./scripts/build-driver.sh; fi
echo 'Installing Local TTS Mic requires administrator access and briefly interrupts ALL system audio.'
sudo /usr/sbin/installer -pkg "$PWD/build/Local TTS Mic Driver.pkg" -target /
echo 'Driver installed; Core Audio was restarted. Reopen the microphone selector in your call app.'
