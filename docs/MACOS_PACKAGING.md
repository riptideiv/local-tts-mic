# macOS installer

The installer is under development and is currently a local test artifact. No `.pkg` has been uploaded to a GitHub release.

## Installation flow

1. Open the `.pkg` in Finder. Installer copies **Local TTS Mic.app** to `/Applications` and installs the virtual microphone in `/Library/Audio/Plug-Ins/HAL/LocalSpeakMic.driver`.
2. Finish active calls and quit any running copy of the app before installing. The microphone component requires administrator authentication and briefly restarts all Mac audio. The installer explains this before installation.
3. Open Local TTS Mic from Applications. Its setup window downloads the speech models, FFmpeg, and example voices. Allow at least 10 GB free and several GB of internet downloads.
4. After setup, try Preview, then select Local TTS Mic as the input in the receiving call/game app.

The packaged build requires **Apple Silicon and macOS 15 or newer**. The pinned orjson dependency contains a macOS 15 native extension; the builder audits every native deployment target and enforces the packaged minimum in both the app and Installer. Source code still targets macOS 14, whose dependency compatibility remains unverified.

Recipients do not need Terminal, Git, Homebrew, Python, or Command Line Tools. The app includes a standalone Python interpreter, pinned Python dependencies, Open JTalk dictionary, and pinned GPT-SoVITS source. The models and FFmpeg download on first launch, with checksums where provided by the source or the pinned download manifest. The restricted JSUT example remains optional.

## Storage and updates

The app bundle is read-only. Models, example voices, generated speech, caches, and setup receipts live in `~/Library/Application Support/Local Speak/Managed/runtime/`. Existing settings and imported voice profiles retain the original `~/Library/Application Support/Local Speak/` path.

Code comes from the installed app; no checkout path is embedded. Python works after the bundle is moved. The app can be replaced without reinstalling model weights. Upstream source is versioned per commit; shared model weights are outside those versioned directories. Old source directories are retained during upgrades. Repairs verify existing downloads and retain completed files. A failed setup never creates its completion marker; an operating-system file lock is released if setup quits or crashes.

Source builds still use the checkout's `runtime/` and the existing developer setup script. They are separate from packaged installations.

## Building locally

On an Apple Silicon development Mac with Xcode tools and uv installed:

```sh
python3 scripts/package-macos.py
```

The builder provisions Python 3.11.15, installs the pinned dependency lock into that standalone distribution, provisions its Japanese dictionary before signing, embeds the pinned upstream source, and checks dynamic library references and symlinks for dependencies outside the app. It signs nested code before sealing the outer app, then builds the app and driver components into one Installer package.

Output is in `build/distribution/`:

- `local-tts-mic-1.1.0-arm64-unsigned.pkg`: local test installer.
- `SHA256SUMS`: installer checksum.
- `app-root/Applications/Local TTS Mic.app`: staged portable app.

Builds cache the standalone Python environment under `build/package-cache/`. A changed Python version or requirements lock rebuilds that environment. The package contains no user settings, recordings, model weights, runtime logs, or source checkout. The builder never invokes Installer or restarts system audio.

## Signing and notarization

A normal public download requires **Developer ID Application** and **Developer ID Installer** certificates. Apple Development certificates are not substitutes. Supply identity names through the environment:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: …'
export DEVELOPER_ID_INSTALLER='Developer ID Installer: …'
python3 scripts/package-macos.py --sign --notarize local-tts-mic
```

The notarization profile must already exist in Keychain. The build signs nested native libraries, Python and its JIT entitlements, the app, the driver, and the installer. The embedded driver-repair installer and final combined installer are submitted and stapled separately. The final step verifies Gatekeeper. Without signing credentials, the output is named `-unsigned.pkg` and is a local test artifact.

References: [Apple package signing](https://help.apple.com/xcode/mac/current/en.lproj/deve51ce7c3d.html), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [uv standalone Python distributions](https://docs.astral.sh/uv/concepts/python-versions/).

## Before public distribution

Test the signed/notarized installer on a second Apple Silicon Mac without developer tools, including installation, first-run downloads, Preview, a received-audio call test, repair, upgrade, and removal. Review the bundled Python dependency and dictionary notices. Check the driver restart notice and the installer’s architecture/OS restrictions. Do not treat successful payload extraction as an installed-driver or Gatekeeper test.

The current work does not upload this package or create a GitHub release.

## Local validation

- 27 Python tests passed, including unsafe archives, exclusive setup locking, retained model weights, FFmpeg integrity/repair, and interrupted setup completion markers.
- 12 Swift tests passed. The existing driver harness and address/undefined/thread sanitizer checks passed after the portable path changes.
- The portable app's native libraries, deployment targets, and symlinks passed checks for dependencies outside the bundle. Installer accepted the combined package's distribution and both selected components without installing them.
- A relocated, read-only app completed packaged setup and a real CPU private Preview. First audio in that run was 5.5 seconds. Its bundle seal remained valid after setup and speech generation.
- The native first-run setup sheet was reviewed. Starting setup showed its download phases; Cancel download stopped it, retained completed files, left no completion marker, and enabled retry.
- The setup test used APFS clones of previously verified public model, reference, and language-data caches, plus a fresh pinned FFmpeg download. This does not establish fresh-download performance or behavior on a second Mac.
- Developer ID signing, notarization, Gatekeeper acceptance, installing the combined package into `/Applications`, and restarting the system audio driver have not been tested in this pass. No package has been uploaded or published.
