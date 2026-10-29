# Demo assets and reproduction

`assets/app.png` is a capture of the actual native app after its real GPT-SoVITS worker completed a private Preview. No UI success state or timing was fabricated. The capture uses default settings and starter voices, excludes the user's saved voices/phrases, and does not send audio to the virtual microphone. `assets/onboarding.png` shows the native first-run guidance. `assets/icon.png` comes from the existing AppKit icon generator.

`assets/hello.wav` was generated locally by the real CPU worker using GPT-SoVITS v2ProPlus and the public-domain LJ Speech LJ001-0001 reference (Linda Johnson / Keith Ito). It says: **Hello! My voice is running locally on this Mac.** The 32 kHz mono PCM WAV is 3.34 seconds. Its model revisions and SHA-256 are in `assets/hello.json`. This is a synthesis sample, not a call recording or the original corpus reference. Model/reference terms remain separate from the app's MIT license; see THIRD_PARTY.md.

## Reproduce

After setup/build, with the engine idle:

```sh
# Actual inference and private speaker/headphone playback, followed by a window capture.
LOCALSPEAK_SUPPORT="$PWD/build/capture-support"   'build/Local TTS Mic.app/Contents/MacOS/LocalSpeak'   --capture-demo "$PWD/docs/assets/app.png" --capture-live-preview

# Interface-only dark-mode capture at the supported minimum window size.
LOCALSPEAK_SUPPORT="$PWD/build/capture-support"   'build/Local TTS Mic.app/Contents/MacOS/LocalSpeak'   --capture-demo "$PWD/build/app-dark-compact.png" --capture-dark --capture-compact

# First-run state with an empty runtime root; speech remains disabled.
LOCALSPEAK_ROOT="$PWD/build/empty-root" LOCALSPEAK_SUPPORT="$PWD/build/capture-support"   'build/Local TTS Mic.app/Contents/MacOS/LocalSpeak'   --capture-demo "$PWD/docs/assets/onboarding.png"

# Real model-validation samples and timing report.
runtime/.venv/bin/python scripts/validate_engine.py --device cpu
```

The capture helper saves the native content view, not the desktop, so notifications/account names do not leak into the screenshot. It does not persist preferences. The live option intentionally plays one private preview through the current output. The interface-only option labels itself “speech disabled” and never invents a Ready state. New synthesis can vary with environment versions and hardware; update the provenance file when replacing the sample.

For a Reddit video, record the actual overlay and received-audio meter for 15–25 seconds, then show Preview leaving that meter silent. Only describe the receiving app as tested after verifying its received audio. This repo's screenshot/audio pair does not demonstrate remote call transmission.
