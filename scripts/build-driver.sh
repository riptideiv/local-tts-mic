#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MIC_PROJECT_ROOT="$PWD"
./scripts/build-icon.sh
python3 driver/generate.py
mkdir -p build/LocalSpeakMic.driver/Contents/MacOS
xcrun clang -std=c11 -O2 -fblocks -fvisibility=hidden -Wall -Wextra \
  -Wno-unused-parameter -Wno-unused-variable -Wno-unused-function \
  -mmacosx-version-min=14.0 -I driver -bundle -framework CoreAudio -framework CoreFoundation \
  driver/generated/LocalSpeakMic.c -Wl,-exported_symbol,_LocalSpeakMic_Create \
  -o build/LocalSpeakMic.driver/Contents/MacOS/LocalSpeakMic
python3 scripts/package_driver.py
codesign --force --sign - build/LocalSpeakMic.driver
codesign --verify --deep --strict build/LocalSpeakMic.driver
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -I Sources/CMicTransport/include Tests/Driver/driver_test.c Sources/CMicTransport/MicTransport.c \
  -framework CoreAudio -framework CoreFoundation -o build/driver-test
build/driver-test "$MIC_PROJECT_ROOT/build/LocalSpeakMic.driver" | tee build/driver-test-report.txt
mkdir -p build/installer-root/Library/Audio/Plug-Ins/HAL
ditto build/LocalSpeakMic.driver build/installer-root/Library/Audio/Plug-Ins/HAL/LocalSpeakMic.driver
pkgbuild --analyze --root build/installer-root build/components.plist
python3 - <<'PY'
from pathlib import Path
import plistlib
path = Path('build/components.plist')
components = plistlib.loads(path.read_bytes())
for component in components:
    component['BundleIsRelocatable'] = False
    component['BundleHasStrictIdentifier'] = True
path.write_bytes(plistlib.dumps(components))
PY
pkgbuild --root build/installer-root --identifier local.localspeak.mic.installer --version 0.1.0 \
  --component-plist build/components.plist --scripts driver/installer-scripts \
  --install-location / --ownership recommended 'build/Local TTS Mic Driver.pkg'
