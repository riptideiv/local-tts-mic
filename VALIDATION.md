> Historical validation notes use the former Local Speak display name. Current source-release checks are recorded in [the release review](docs/RELEASE_REVIEW.md).

# Historical single-Mac validation

These are pre-existing development records, retained for context. Referenced runtime artifacts are local and are not shipped in this repository. This history does not certify fresh installs, every macOS version, or all call apps. Current release-preparation checks are recorded in [docs/RELEASE_REVIEW.md](docs/RELEASE_REVIEW.md).

Tested on an Apple M2 Max MacBook Pro (32 GB), macOS Tahoe 26.7.1. Tests used real GPT-SoVITS v2ProPlus weights and the shipped reference-voice installer.

## Speech generation

The actual worker protocol generated non-silent, finite audio for English, Mandarin, Japanese, and mixed-language input. Local Faster Whisper small transcription recovered these CPU-generated test samples:

- English: “Hello, my voice is running locally on this Mac.”
- Mandarin: “你好，这是在桌台电脑上生成的语音” (ASR substituted a character in “这台”).
- Japanese: “こんにちは。この音声はパソコンで生成しています。”

These are a functional intelligibility check, not a broad voice-quality evaluation. Reference voices are examples; a good custom recording can improve similarity and pronunciation.

## Measured latency

| Test | CPU first audio | CPU total synthesis | MPS first audio | MPS total synthesis |
| --- | ---: | ---: | ---: | ---: |
| English, first request | 4.38 s | 6.51 s | 23.34 s | 30.31 s |
| Mandarin, first request | 4.83 s | 5.04 s | 16.09 s | 16.70 s |
| Japanese, first request | 1.15 s | 2.68 s | 5.32 s | 9.09 s |
| English, warm repeat | 1.29 s | 3.34 s | 0.88 s | 4.64 s |

Model loading took approximately 7.5 seconds on CPU and 9.2 seconds on MPS. Timings are from short test sentences; message length, first-use caches, reference changes, and concurrent workloads affect latency. CPU remains the default because it was faster overall and across first-use multilingual requests. The MPS test ran outside the agent sandbox to allow Metal access.

Raw WAVs and timing reports: `runtime/validation-cpu/` and `runtime/validation-mps/`.

## Worker lifecycle

`scripts/validate_lifecycle.py` verified actual model execution after invalid input, cancellation after the first audio fragment, compatible imported checkpoint loading, and automatic mixed-language segmentation. The worker stopped emitting the canceled message and successfully generated subsequent messages. The checkpoint-import test uses the pretrained checkpoint pair via explicit paths; no example voice fine-tuning was performed.

## Audio routing

The native diagnostic recorded the installed eight-channel VB-Cable input while playing a generated WAV through the app's actual audio router. Speech appeared on channels 1 and 2 (RMS approximately 0.0288); channels 3–8 stayed silent. Input capture was 48 kHz and the generated source was 32 kHz, exercising resampling. The baseline before playback was silent.

The separate preview-isolation test also passed: all eight VB-Cable channels stayed silent while private preview played. Its report is saved at `runtime/loopback-preview.json`. Broadcast evidence is in `runtime/loopback-broadcast.json` and its corresponding WAV.

## Build and automated checks

- Native release `.app` built and ad-hoc signed successfully.
- Nine Python boundary-validation tests passed.
- Two Swift tests passed for the native/worker voice-profile contract and explicit routing defaults.
- Local training WebUI served HTTP 200 on `127.0.0.1:9874`; dependency versions are locked for compatibility with Gradio 4.

The native UI test opened the overlay, entered a draft, dismissed it with Escape, confirmed the draft was retained, then submitted it with Enter. The overlay closed, speech passed through the real worker/router, and the conversation reached Done with WAV export available. The final installed app also opened the overlay with Control–Option–Space and returned to the main window with Escape. The global shortcut uses Carbon registration; focused-window fallback handles targeted AppKit/assistive input events.

The complete setup/repair script completed successfully against the pinned environment. The app was copied to `~/Applications/Local Speak.app`, its signature verified, and it was left running with the CPU engine ready.

Actual fine-tuning, every third-party call app, exclusive-full-screen games, unplugging a physical monitoring device, and every input-method configuration are outside this validation run.

## Playback regression, version 1.0.1

The first release's standalone loopback test did not cover a long-lived app's stopped or reconfigured audio engine. A user reported silent Speak and Preview, and a live capture of the running app reproduced silent VB-Cable output despite valid generated WAVs. Restarting the app restored output; a second live UI request after an idle pause also produced speech.

The fix validates engine state, device ID, and audio format before reuse, handles engine configuration notifications, resets drained player timelines, and closes hardware routes between completed messages. Preview now follows the system output by default rather than automatically pinning the built-in speakers. This machine's system output had changed to AB13X USB Audio.

The native recovery regression deliberately stops/reconfigures the output engine between two playbacks and records VB-Cable again for the second playback. Its measurements are in `runtime/loopback-recovery.json`. Live-app captures are in `runtime/live-ui-before.wav` (silent), `runtime/live-ui-diagnostic.wav` (speech), and `runtime/live-ui-second.wav` (speech after idle). Audio route diagnostics are in `runtime/logs/audio.log`.

After installing 1.0.1, a new live UI Speak request was captured from VB-Cable with peak amplitude 0.221 on channels 1–2 and silence on channels 3–8. Local ASR recovered the complete sentence, “The microphone output is working after the audio fix.” Evidence: `runtime/live-ui-fixed.wav` and `runtime/live-ui-fixed-report.json`. The app's private Preview routed to AB13X USB Audio, and the user confirmed hearing it. All 12 automated tests passed (nine Python, three Swift). Discord's own call transmission has not been directly tested.

## Freezing and queue recovery, version 1.0.2

The user's subsequent logs showed AVAudioEngine routes stopping between creation and scheduling. Some callbacks arrived in roughly 0.03–0.09 seconds for multi-second buffers; others never arrived. Configuration notifications invalidated routes and discarded callbacks, while AppModel waited for its pending-buffer count forever. The interruption handler also cleared queued jobs, and hardware setup ran synchronously on the UI thread.

Playback now uses AudioQueue with decoding, resampling, device setup, and disposal on a serial background queue. Each fragment has an individually tracked completion ticket; callbacks settle once, and callbacks from old jobs cannot affect new jobs. A playback deadline includes cumulative audio duration plus eight seconds of startup margin. Ninety seconds without synthesis progress fails the active job. Cancellation waits at most three seconds for acknowledgement before replacing the worker. These failures preserve queued jobs. Engine logs append across restarts, and audio.log includes correlated worker and playback events.

A persistent AudioQueue prototype exposed another driver behavior: completion callbacks continued while VB-Cable became silent after a few jobs. Both FFmpeg and native input recordings caught this, despite all jobs reaching Done. The final backend closes drained outputs between jobs and reopens them on the background queue. Queue status alone is not sufficient validation.

The final native test submitted six two-sentence messages, waited idle for two seconds, then submitted three more using the selected custom voice. All nine jobs finished in 64.6 seconds. A 50 ms main-thread timer's longest interval was 50.7 ms. Native VB-Cable capture verified all 18 complete generated fragments in order, with waveform correlations from 0.963 to 1.000 and the expected approximately 0.8 gain. Channels 1–2 carried speech; channels 3–8 remained silent. Evidence: `runtime/queue-stress-verified.json`, its WAV, and `runtime/queue-stress-verified-capture.json`. The diagnostic allows input buffers to flush before stopping capture; comparison searches forward to distinguish repeated deterministic fragments.

Private preview completed on AB13X USB Audio while all eight cable channels remained silent (`runtime/loopback-preview-audioqueue.json`). Output close/reopen was also tested with two complete playbacks (`runtime/loopback-audioqueue-complete.json`).

Nine Swift and nine Python tests passed. The Swift regressions exercise missing and duplicate completions, multi-output errors, late callbacks, preserved backlog after playback failure, missing cancellation acknowledgements, playback timeout, and unresponsive synthesis. `--queue-test` and `scripts/validate_capture.py` reproduce the actual delivery test. Physical device unplugging, a long-duration soak, and Discord call transmission remain untested.

## Native microphone and monitoring, version 1.1.0

Local Speak Mic is installed in `/Library/Audio/Plug-Ins/HAL/LocalSpeakMic.driver` and enumerates as a two-channel, 48 kHz Float32 Core Audio device. The user approved installation and the Core Audio restart. The app now uses the native IO transport for microphone delivery, keeping its callback running with silence between messages. Physical preview uses the background AudioQueue renderer. Preview follows the selected system output exactly; this run used the MacBook Pro speakers.

Live capture of the installed app verified send + preview reached both native microphone channels (RMS 0.03361). Private preview completed through the speakers while both microphone channels remained exactly silent. Reports: `runtime/native-mic-send-preview-final.json` and `runtime/native-mic-private-preview-final.json`.

The final queue test completed nine two-sentence messages, including a two-second idle gap, in 65.25 seconds. The longest interval on the 50 ms main-thread timer was 51.51 ms. Recorded microphone audio contained all 18 complete generated fragments in order, with waveform correlations from 0.9437 to 1.0000 and gains from 0.7552 to 0.8000. Reports: `runtime/native-mic-queue-final.json`, `runtime/native-mic-queue-final.wav`, and `runtime/native-mic-queue-final-capture.json`. This verifies actual delivered audio as well as queue completion.

Twelve Swift and nine Python tests passed. Driver tests covered 250 simulated utterances and concurrent producer/two-reader transport; AddressSanitizer, UndefinedBehaviorSanitizer, and ThreadSanitizer checks passed during driver development. The driver and C transport were promoted unchanged from that validated prototype.

The installed UI exposes “Hear while speaking” in both the main composer and typing overlay. Toggling it updates the shared state, primary action, and Enter hint to “Speak + preview”; Preview remains private. Unit tests verify that changing monitoring preserves the active message and queue, and that each queued message retains its chosen delivery mode. Native UI checks confirmed the original custom voice and Mandarin selection were retained, the overlay toggle is visible, and the app returned to Ready. Discord call transmission, a long-duration soak, and physical output disconnection remain untested.
