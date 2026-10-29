#!/usr/bin/env python3
from pathlib import Path
import plistlib
import shutil

root = Path(__file__).resolve().parents[1]
bundle = root / 'build/LocalSpeakMic.driver'
resources = bundle / 'Contents/Resources'
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'build/AppIcon.icns', resources / 'DeviceIcon.icns')
shutil.copy2(root / 'driver/vendor/LICENSE.txt', resources / 'Apple-Sample-LICENSE.txt')
factory = 'C3D20C23-21D3-4EAF-A175-9FD902A8391D'
info = dict(CFBundleExecutable='LocalSpeakMic', CFBundleIdentifier='local.localspeak.mic.driver',
            CFBundleName='Local TTS Mic', CFBundlePackageType='BNDL', CFBundleInfoDictionaryVersion='6.0',
            CFBundleVersion='1', CFBundleShortVersionString='0.1.0', LSMinimumSystemVersion='14.0',
            CFPlugInDynamicRegistration=False,
            CFPlugInFactories={factory: 'LocalSpeakMic_Create'},
            CFPlugInTypes={'443ABAB8-E7B3-491A-B985-BEB9187030DB': [factory]})
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
