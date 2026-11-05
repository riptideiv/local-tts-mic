# Install, update, troubleshoot, remove

## macOS installer preview

Download `local-tts-mic-1.2.0-arm64-unsigned.pkg` from the [1.2.0 release](https://github.com/riptideiv/local-tts-mic/releases/tag/v1.2.0). Requires **Apple Silicon and macOS 15+**. This preview is **unsigned and not Apple notarized**. CPU is the default; MPS is experimental. Minimum memory requirements and fresh setup on additional Macs remain unverified.

1. Finish active calls and quit Local TTS Mic. Open the `.pkg`, follow Installer, and authenticate when asked. It copies the app to `/Applications` and installs its virtual microphone. The driver step **briefly restarts all Mac audio**.
2. Open Local TTS Mic from Applications. Click **Install / repair** in the setup window. First launch downloads several GB of speech models, FFmpeg, and example voices; allow at least **10 GB free** for setup, caches, and generated audio. No Terminal, Git, Homebrew, or developer tools are needed.
3. Try **Preview** first. To use it in calls or games, select **Local TTS Mic** as that app's microphone. Keep your normal speakers/headphones selected for output.

If setup is interrupted, retry from the same setup window. Completed downloads are retained and verified. Models, caches, generated speech, logs, and setup receipts live under `~/Library/Application Support/Local Speak/Managed/runtime/`. Voices/preferences retain `~/Library/Application Support/Local Speak/`. A packaged app can be moved without rebuilding; its code/runtime dependencies are inside the app, while downloaded models remain in Application Support.

For v1 models, including the recommended Kusanagi Nene pair, see [voice import](VOICES.md#v1-checkpoints). Import both checkpoints, select **v1**, and supply a permitted 3–10 second reference and exact transcript. The installed pretrained model remains v2ProPlus.

## Gatekeeper and signatures

The downloadable preview's app is ad-hoc signed; the `.pkg` has no Developer ID Installer signature. Neither is notarized by Apple. A passing code-seal check does not establish publisher identity or Gatekeeper acceptance. Verify that the download comes from this repository and compare its hash with the release's `SHA256SUMS` if needed.

macOS may refuse to open the installer or app. Apple documents the per-item exception in [Safely open apps on your Mac](https://support.apple.com/102445). Only allow a download after reviewing its source and deciding you trust it. Do not disable Gatekeeper globally. A source build is an alternative if you prefer to inspect and build the code yourself.

## Build from source

Install Command Line Tools providing Swift 6+, and [Homebrew](https://brew.sh), uv, and FFmpeg as described in the [README](../README.md#build-from-source). Run `./scripts/setup.sh`, `./scripts/build.sh`, then open `build/Local TTS Mic.app`. You can instead build the app first and use its setup panel. Source APIs target macOS 14, but the pinned dependency set's macOS 14 compatibility is unverified; the packaged build enforces macOS 15+.

Source builds use `runtime/` in the checkout and retain that source-folder path in Info.plist. Keep the folder after copying the source-built app into Applications. Moving it requires rebuilding and rerunning setup to regenerate starter paths. Imported checkpoints/references are copied into Application Support by the importer. Files selected manually in the voice editor stay at their selected checkpoint paths.

Try Preview without a driver, then run `./scripts/install-driver.sh` when audio can be interrupted. **Audio → Install Local TTS Mic** opens the driver package. Local source-built app/driver seals can be checked with:

```sh
codesign --verify --deep --strict 'build/Local TTS Mic.app'
codesign --verify --deep --strict build/LocalSpeakMic.driver
```

## Update

For a packaged install, quit the app and finish calls, then open the newer `.pkg`. It replaces the app/driver and retains saved voices, settings, and downloaded model data. A changed runtime manifest can request setup/repair; completed model downloads are reused. Back up Application Support before major upgrades.

For a source install, update the checkout, rerun `./scripts/setup.sh`, then `./scripts/build.sh` and optionally `./scripts/install.sh`. Reinstall the driver if it changed. An update does not silently replace your imported checkpoints.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| macOS blocks the installer or app | Read the unsigned-build notice and Apple's per-item Gatekeeper guidance above. |
| Download checksum mismatch | Retry setup; mismatched partial downloads are discarded. Persistent failure needs a reviewed upstream asset update. |
| Interrupted packaged setup | Open Setup / repair runtime and retry; completed files are retained. |
| Source setup says it is running | Let the other setup finish. After a crash, confirm no setup is running before removing `runtime/.setup-lock`. Packaged setup releases its OS lock automatically. |
| Missing Local TTS Mic | Use Audio's driver installer, refresh devices, reopen Audio MIDI Setup, or restart the Mac. Do not reinstall during a call. |
| Test tone works, receiving app is silent | Select Local TTS Mic in that app and check input level/noise suppression. |
| Preview silent | Select your speakers/headphones under Audio, check volume, and ensure they are connected. |
| Engine stopped | Open the engine log from Audio; restart on CPU and use setup/repair for missing resources. |
| v1 model fails | Select v1 and a matching GPT/SoVITS pair; check the reference language/transcript and 3–10 second duration. |
| Shortcut fails in a game | Change the shortcut under Audio or use the menu bar; exclusive keyboard capture may swallow it. |
| Source `uv`/`ffmpeg` missing | Install uv/FFmpeg, then run source setup again. Packaged installs include/provision these dependencies. |
| Old Swift / manifest error | Install/select Xcode or Command Line Tools providing Swift 6+. |
| Moved the source folder | Rerun setup and build from the new location. Packaged installs do not depend on a checkout. |

Source contributors can run `python3 scripts/doctor.py` for read-only diagnostics; `--json` gives a compact report without personal paths. It checks files rather than proving Core Audio loaded the driver. The queue has watchdog recovery for stalled synthesis/playback. A failed message preserves queued messages; Stop clears pending messages and Preview stays private. Report UI job status and real received audio when investigating delivery problems.

## Uninstall

Quit the app and finish calls. Remove `/Applications/Local TTS Mic.app` (or your source-built app copy) in Finder. To remove the virtual microphone without a checkout, use Finder's **Go → Go to Folder…**, open `/Library/Audio/Plug-Ins/HAL/`, remove only `LocalSpeakMic.driver`, authenticate if asked, and restart the Mac so Core Audio unloads it.

Source users can instead run `./scripts/uninstall-driver.sh --confirm`, which removes the same driver, forgets its installer receipt, and restarts Core Audio immediately. No uninstall operation runs automatically.

To erase models, generated audio, saved voices, and preferences, remove `~/Library/Application Support/Local Speak/` after backing it up. Source models/caches also live in the checkout's `runtime/`. Imported library files are copies; original downloaded folders and manually selected checkpoint files elsewhere remain in place.

## Existing development installs

The app was previously named Local Speak. Internal bundle identifiers, the driver filename, and `~/Library/Application Support/Local Speak/` are retained for compatibility. Reinstall the driver to update its displayed name; an older one can still appear as Local Speak Mic. Quit the old app before opening the new one, and remove the older app bundle after verifying the new install.
