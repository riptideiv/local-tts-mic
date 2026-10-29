# Local TTS Mic

The main Local TTS Mic app now uses this dedicated Core Audio virtual microphone. It publishes two Float32 channels at a fixed 48 kHz with the persistent device UID `local.localspeak.mic.device.v1`.

Build the app, driver, offline tests, and installer with `./scripts/build.sh` from the project root. `build/Local TTS Mic Driver.pkg` installs the driver into `/Library/Audio/Plug-Ins/HAL/LocalSpeakMic.driver`. Installation requires administrator authentication and briefly restarts Core Audio through its postinstall script. App installation is separate: `./scripts/install.sh` updates the existing Local TTS Mic app while retaining its saved voices, preferences, and shortcuts.

The source scaffolding is Apple's MIT-licensed Audio Server Driver Plug-in sample in `vendor/`. The download and source are pinned in `upstream.json`. `generate.py` validates the source hash and generates the derivative with the device name, persistent UIDs, fixed format, streams, and loopback hooks. The original illustrative volume/data-source controls are not advertised.

`Loopback.h` implements a lock-free, time-addressed stereo ring. Absolute frame tags distinguish current samples from old ring revolutions; unwritten or overwritten frames yield silence. Readers do not consume each other's data. The internal loopback offset is 512 frames; actual application latency also includes HAL buffering. A full IO restart clears the ring and changes the clock seed. The device cannot become the default output or system-sound device.

`Sources/LocalSpeak/NativeMicRenderer.swift` drives an `AudioDevice` IO procedure through `Sources/CMicTransport/`. PCM allocation and reclamation happen on the control queue. The audio callback copies queued PCM or fills silence; it does not allocate, lock, log, or invoke Swift completions. It remains running between utterances to keep the device timeline alive. Stop shuts down the IO procedure before freeing PCM. Private headphone output uses a separate renderer.

The driver can be tested in a disposable process without installing it:

```sh
./scripts/build-driver.sh
./scripts/test-driver-sanitizers.sh
```

The compiled-bundle harness covers factory/property discovery, box and stream enumeration, format rejection, ring wrap, independent and concurrent readers, restart reset, and 250 utterances from the app's PCM sender through the actual loaded driver. AddressSanitizer and UndefinedBehaviorSanitizer cover both components. The concurrent transport test checks 411,000 frames with ThreadSanitizer.

After installation, with the normal app closed:

```sh
open -n -W 'build/Local TTS Mic.app' --args --queue-test "$PWD/runtime/native-queue.json"
runtime/.venv/bin/python scripts/validate_capture.py \
  runtime/native-queue.json runtime/native-queue.wav runtime/native-queue-capture.json
```

This uses the English example voice in memory without changing the saved voice, language, or monitoring preference. All nine jobs and all 18 generated fragments must pass the recording comparison. The native input is bound by UID, so the diagnostic never records a physical microphone.

`--loopback-test WAV REPORT --monitor` tests simultaneous microphone and headphone playback. `--preview --monitor` checks that Preview remains private even with monitoring enabled. The receiving app, such as Discord, should select **Local TTS Mic** as its input and retain speakers/headphones as its output.

The original prototype snapshots are retained in Git history rather than shipped as additional app copies. The current app does not require VB-Cable. To remove the native driver after closing calls, run `./scripts/uninstall-driver.sh --confirm`; this restarts Core Audio.
