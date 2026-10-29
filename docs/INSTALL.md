# Install, update, troubleshoot, remove

## Supported preview

Apple Silicon; macOS 14+ APIs; Swift 6+ compiler; Python 3.11 provisioned by uv; FFmpeg on PATH. The original end-to-end run was on an M2 Max (32 GB), macOS 26. This does not establish an 8 GB memory minimum or certification on every supported OS. CPU is the default; MPS is experimental.

Run `./scripts/setup.sh`, `./scripts/build.sh`, and open `build/Local TTS Mic.app`. You can instead build the app first and use its setup panel. Install Command Line Tools with `xcode-select --install`, and uv/FFmpeg with `brew install uv ffmpeg` (Homebrew must already be installed). Setup needs several GB of downloads; reserve at least 10 GB free for dependencies, cached archives, extraction, and generated audio. Slow networks can take much longer than synthesis itself.

Try **Preview** first. Driver installation is optional until you want a virtual microphone. Run `./scripts/install-driver.sh` only when calls and audio work can be interrupted: its package postinstall restarts Core Audio. **Audio → Install Local TTS Mic** opens the same installer. Choose Local TTS Mic as the receiving app’s microphone. The driver does not become your default system output.

The app retains the absolute source-folder path in its Info.plist. Keep that folder after copying the app into Applications. Moving it requires rebuilding and reinstalling the app; rerun setup to regenerate starter reference paths. Custom checkpoint files stay at their imported locations.

## Gatekeeper and signatures

Local builds use ad-hoc signing. They are not Developer ID signed or Apple notarized. Verify local bundles with:

```sh
codesign --verify --deep --strict 'build/Local TTS Mic.app'
codesign --verify --deep --strict build/LocalSpeakMic.driver
```

If macOS blocks a downloaded source-built app, prefer building from inspected source yourself. Apple documents per-app exceptions in [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). Do not disable Gatekeeper globally. A future downloadable app needs portable runtime support, Developer ID signing, installer signing, and notarization before it can be described as a normal drag-and-drop release.

## Update

Quit Local TTS Mic using its menu bar icon or Command–Q, finish active calls, update your source checkout, rerun `./scripts/setup.sh`, then `./scripts/build.sh`. Optional: `./scripts/install.sh`. Reinstall the driver only if its implementation/package changes. Saved preferences and imported reference recordings are retained in Application Support. Back them up before major upgrades. Update does not silently replace user checkpoints.

## Troubleshooting

`python3 scripts/doctor.py` is read-only, makes no network requests, and exits nonzero when required runtime pieces are missing. `--json` provides a compact report without personal file paths. It checks installed driver files, not whether Core Audio has loaded them; use Audio MIDI Setup for that.

| Symptom | Next step |
| --- | --- |
| `uv`/`ffmpeg` missing | `brew install uv ffmpeg`, then run setup again. |
| Old Swift / manifest error | Install/select Xcode or Command Line Tools providing Swift 6+. |
| Download checksum mismatch | Retry setup; mismatched partial downloads are discarded. Persistent failure needs a reviewed upstream asset update. |
| Setup says it is running | Let the other setup finish. After an interrupted/crashed setup, confirm none is running, remove `runtime/.setup-lock`, and retry. |
| Interrupted model download | Rerun setup. Large files resume and verify available checksums before replacement. |
| Missing Local TTS Mic | Build/install its driver, refresh devices, reopen Audio MIDI Setup or reboot. Do not reinstall during a call. |
| Test tone works, receiving app is silent | Select Local TTS Mic in that app and check input level/noise suppression. |
| Preview silent | Select your speakers/headphones under Audio, check volume, and ensure they are connected. |
| Engine stopped | Open `runtime/logs/engine.log`; restart on CPU; use setup/repair for missing resources. |
| Moved the source folder | Rerun setup, build, and optional app install from its new location. |
| Shortcut fails in a game | Change the shortcut under Audio or use the menu bar; exclusive keyboard capture may swallow it. |
| Training page fails | Check `runtime/logs/training.log` and whether localhost port 9874 is free. |

The queue has watchdog recovery for stalled synthesis and playback. A failed message preserves queued messages. Stop clears pending messages; Preview always stays private. Report both UI job status and real received audio when investigating delivery problems.

## Uninstall

Quit the app, close calls, and run:

```sh
./scripts/uninstall-driver.sh --confirm
```

This removes only `/Library/Audio/Plug-Ins/HAL/LocalSpeakMic.driver`, forgets its installer receipt, and restarts Core Audio. Remove `~/Applications/Local TTS Mic.app` if you copied it there. Delete the source folder to remove models, caches, logs, and generated speech. To erase saved voices/preferences too, remove `~/Library/Application Support/Local Speak/` after backing up anything you need. Reference clips in that folder are copies; imported checkpoint files remain at their original locations. No uninstall operation is run automatically.

## Existing development installs

The app was previously named Local Speak. Its internal bundle identifiers, driver bundle filename, and `~/Library/Application Support/Local Speak/` storage path are retained for compatibility. Rebuild and reinstall the driver to update its displayed name to Local TTS Mic; an older installed driver can still appear as Local Speak Mic. Quit the old app before opening the renamed app, and remove the old app bundle after verifying the new build.
