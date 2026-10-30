#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
swift build -c release --disable-sandbox --jobs 2
APP="$ROOT/build/Local TTS Mic.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LocalSpeak "$APP/Contents/MacOS/LocalSpeak"
./scripts/build-icon.sh
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
python3 - "$APP" "$ROOT" <<'PY'
import plistlib,sys
from pathlib import Path
app, root = sys.argv[1:]
info = dict(CFBundleExecutable='LocalSpeak', CFBundleIdentifier='local.localspeak.app',
    CFBundleName='Local TTS Mic', CFBundleDisplayName='Local TTS Mic', CFBundleVersion='5',
    CFBundleShortVersionString=Path(root, 'VERSION').read_text().strip(), CFBundlePackageType='APPL', LSMinimumSystemVersion='14.0',
    NSHighResolutionCapable=True, CFBundleIconFile='AppIcon.icns', LocalSpeakRoot=root,
    NSMicrophoneUsageDescription='Record the virtual microphone during an explicit routing test.')
Path(app, 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$APP"
./scripts/build-driver.sh
echo "$APP"

