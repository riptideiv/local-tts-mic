# Contributing

Start with an issue describing your use case, especially for new engines or a redesign. Small focused fixes and setup reports are welcome. Use respectful, specific feedback and keep private audio/transcripts out of issues.

## Fast development loop

Use an Apple Silicon Mac, Swift 6+, Command Line Tools, and uv. No speech models or installed microphone driver are needed for the small tests:

```sh
uv venv --python 3.11
uv pip install pytest==8.3.5
./scripts/test.sh
```

This runs Python tests, Swift tests, builds/tests the driver in a disposable process, and runs AddressSanitizer, UndefinedBehaviorSanitizer, and ThreadSanitizer. It never installs a system driver or restarts Core Audio. Python tests alone also work on Linux: `python -m pytest Tests -q`.

To develop the real speech path, follow the README setup. Use `./scripts/build.sh` and open the locally built app. `LOCALSPEAK_ROOT` overrides the engine/source root; `LOCALSPEAK_SUPPORT` overrides the app’s settings/reference directory for isolated manual tests. Avoid running two instances against the same support directory.

## Code map

- `Sources/LocalSpeak/`: SwiftUI/AppKit UI, global shortcuts, queue state, worker process and physical/private playback.
- `Sources/CMicTransport/`: real-time PCM producer/consumer. Audio callbacks must not allocate, lock, log, or invoke Swift.
- `engine/`: pinned GPT-SoVITS adapter and JSON-line boundary validation.
- `driver/`: hash-checked derivative of Apple’s MIT sample, time-addressed stereo loopback, installer scripts.
- `scripts/`: setup, model integrity checks, builds, source packaging and actual-audio diagnostics.

## Validation expectations

Run checks relevant to your change. Python changes should keep the stdout JSON-line protocol clean. Queue/audio changes need callback failure, cancellation, and private-preview coverage. Do not import torch into unit tests. Swift tests should use fake worker/audio interfaces and `persistChanges: false` so they do not overwrite your actual voices or settings.

For delivery changes, also capture real virtual-input audio using the commands in `driver/README.md`: verify content and order, idle gaps, preview silence, and microphone + monitoring. Passing unit tests or every job reaching Done does not establish real audio delivery. Write down what you did not test.

The lockfile records the working Python environment; do not mass-update it without a clean setup + real inference/lifecycle check. Model/checksum pin changes require a reviewed source and terms check. Preserve Apple and upstream notices. Never commit runtime assets, personal recordings, logs, generated driver sources, secrets, or build outputs.

Use the PR template to explain the user-visible problem, resulting behavior, and actual validation. For release preparation, see `docs/RELEASING.md`.

For the local app-and-driver installer build and its validation requirements, see [macOS packaging](docs/MACOS_PACKAGING.md).
