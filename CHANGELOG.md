# Changelog

## Unreleased

- GPT-SoVITS v1 checkpoint import and synthesis, with v1/v2 architecture headers, version mismatch errors, and reference-cache invalidation when changing models.

- Hugging Face URL and local-folder voice import, with metadata/transcript discovery, pinned downloads, file verification, and copied checkpoints.
- Small community voice catalogue; private voice previews preserve the selected broadcast voice.

- Local app-and-driver `.pkg` builder with a standalone Python runtime and first-run model downloads. Packaged users do not need Terminal, Git, Homebrew, or developer tools.
- Per-user model storage, portable app paths, cancellable setup with retry, and signing/notarization support. Installer remains a local test artifact pending signing and clean-Mac validation.


## 1.1.0 — public source preview

- Native typing overlay, saved phrases, queue, WAV export, English/Mandarin/Japanese reference-conditioned speech through local GPT-SoVITS.
- Local TTS Mic: dedicated stereo 48 kHz virtual input and native PCM sender; private preview and optional monitoring.
- First-run guidance, optional driver installer link, readable setup prerequisites, and explicit opt-in for the restricted JSUT reference.
- Model-free contributor tests, driver sanitizer checks, CI, read-only diagnostics, uninstall instructions, and reproducible source packaging.
- SHA-256 verification for supplemental models/reference downloads, resumable-download recovery, and stale-cancellation isolation.
- MIT project license and separate third-party terms; public docs omit machine-specific custom voices and prototype copies.

This is a source build. Runtime/models are downloaded into the project folder. No portable/notarized binary or automatic updater is provided. Prior machine-specific validation is recorded in VALIDATION.md.
