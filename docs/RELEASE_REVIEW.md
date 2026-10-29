# Release review — October 28, 2026

**Verdict: prepared for a clearly labeled Apple Silicon source preview.** This is not yet a frictionless consumer download. The app provides a native global typing overlay, local reference-conditioned speech, a virtual microphone, and a separate private preview. This review covers installation, runtime behavior, tests, licensing, documentation, and distribution.

## Findings and patches

| Severity | Finding | Resolution in this branch |
| --- | --- | --- |
| P1 | No commits or public repo; no project license | Preserved existing source locally, prepared changes in a separate worktree based on main, and added an MIT license. The public repository starts from the reviewed source snapshot. |
| P1 | Fresh-clone Swift tests depended on downloaded runtime voices | Contract test now reads committed source metadata. Added a model-free contributor command and Linux/Python + macOS native/build/sanitizer CI. |
| P1 | Late cancel for a completed job could stop another active synthesis | Worker tracks active/pending IDs under its cancellation lock. Only a matching active job stops the pipeline; pending cancels are retained and terminal state is cleaned up. Added a subprocess regression without torch. |
| P1 | Restricted Japanese reference downloaded by default | English/Mandarin default; JSUT is an explicit CLI/UI opt-in with original terms linked. Already installed optional references survive repair. Japanese can use a permitted user reference. |
| P1 | Supplemental resources/reference downloads lacked integrity pins | Added SHA-256 pins for vocabulary, language model, pronunciation archive, and all reference recordings; streaming hashing bounds memory. Completed partial files finalize without an invalid EOF range request; corrupt downloads never replace a good target. |
| P2 | Standalone driver build failed without an app-generated icon | Shared icon build script is now called by both app and driver builds. Standalone build tested before provisioning runtime. |
| P2 | First launch produced setup errors without a clear trial path | Inline setup guidance, usable empty voice selector, separate private-preview path, and optional driver installer link with audio-restart notice. |
| P2 | Setup assumed dependencies were already present and could run concurrently | Explicit platform/tool prerequisites, one setup lock, pinned shallow upstream fetch, required lockfile, and bounded metadata requests. Training/repair cannot run together in the UI. |
| P2 | Install status contradicted the actual audio restart; no removal path | Corrected status and added narrowly scoped, explicit driver uninstall with retained app/user data. No system changes performed during preparation. |
| P2 | Public README included author-specific custom-voice inventory | Replaced with public setup, capability/latency/OS limits, consent guidance, privacy/storage, help and contribution paths. Third-party notices retained. |
| P2 | No demo, issue templates, security guidance or release process | Added a real native screenshot, real local public-domain-reference synthesis sample/provenance, bug/feature templates, contribution/security docs, source packager/checksums, roadmap and launch kit. |
| P3 | Multiple stale app copies obscured the maintained source | Removed experimental snapshots from branch; originals remain in local development history. |
| P2 | First-run help could expand the host window beyond the screen | AppKit now owns the resizable window bounds instead of accepting SwiftUI ideal-size constraints. First-run content scrolls so controls remain reachable at the minimum window size. Verified normal and compact first-run captures. |
| P3 | Save-phrase icon was empty | Native AppKit symbol lookup confirmed `bookmark.badge.plus` is unavailable; replaced with `bookmark` while retaining its accessible label. |

## Validation performed here

All patches are in the separate `codex/release-prep` worktree based on main; main's source was not patched.

- **16 Python tests passed**, including invalid input, multilingual metadata, resumed/ignored-range downloads, checksum failure, completed partial files, optional-reference consent/preservation, and late cancellation.
- **12 Swift tests passed** for routing defaults/migration, queue failure/recovery, late/missing callbacks, watchdogs, and private preview/monitoring isolation. Playback tests use explicit fake voice fixtures and do not depend on installed models, starter voices, or saved user voices. The extracted-source verification checks this boundary.
- **Release app and standalone driver builds passed**; ad-hoc signatures verified. Driver harness: over one million assertions per run, including 250 utterances and simultaneous writer/two-reader behavior.
- **AddressSanitizer + UndefinedBehaviorSanitizer passed** on the loaded driver and native transport. **ThreadSanitizer passed** on 411,000 stereo frames, exactly once and in order. Tests load the driver into a disposable process; no installer or audio restart was run.
- **Setup succeeded with a fresh isolated Python 3.11 environment**, installing 206 pinned packages. `uv pip check` reported all compatible. Existing public model/download caches were cloned into the worktree to avoid redownloading several GB, then checked by setup. This is not an independent clean-Mac download test.
- **Real CPU worker validation passed** for English/Mandarin and a warm English repeat. First audio: 5.06 s / 5.51 s / 1.26 s; synthesized audio: 3.34 s / 4.07 s / 3.34 s. Cold model load: 30.26 s in the fresh environment. Samples were finite and non-silent.
- **Real worker lifecycle validation passed** after invalid input and cancellation, with explicit checkpoint import and mixed English/Japanese/Mandarin text. The updated dispatch has a separate model-free stale-cancel regression.
- **Actual native private Preview completed** for the README capture. Reviewed real light-mode and minimum-size dark-mode native captures; corrected onboarding truncation and an empty voice/icon control. No saved user preferences or custom voices were used in captures.
- The committed source archive was extracted into a new directory with no models or runtime. All 16 Python tests and 12 Swift tests passed there, and both the release app and driver built successfully. SHA256SUMS verification, internal documentation links, tracked-file hygiene, and whitespace checks passed. Source artifacts exclude runtime, models, private recordings, caches and build outputs; the explicitly attributed synthetic demo WAV is the only shipped audio.

Prior real virtual-mic recording/queue measurements remain historical in VALIDATION.md. This pass does not recertify Discord/Zoom transmission, long sessions, unplug/sleep/wake recovery, every input method, VoiceOver, other Macs, or macOS 14 itself. Automated driver tests establish local implementation behavior, not full receiving-app compatibility. The results above are local checks. Current hosted CI status is available in [GitHub Actions](https://github.com/riptideiv/local-tts-mic/actions).

## Remaining release work

1. **Publication checks:** verify hosted CI and repository settings at [riptideiv/local-tts-mic](https://github.com/riptideiv/local-tts-mic). Sharing drafts are in `docs/LAUNCH.md`; no Reddit post is sent by the preparation scripts.
2. **Broader trust evidence:** obtain another Mac's fresh setup report and at least one actual received-audio call test. The README limits its claims accordingly.
3. **Consumer downloads:** portable runtime provisioning, Developer ID/signing credentials, notarization/stapling, third-party distribution review, and a clean-Mac install/uninstall check are required before advertising a normal binary download. The source packager intentionally does not ship this machine's `.app` as portable.
4. **Distribution:** use the real screenshot/audio, adapt the launch draft to a community's current rules, and respond to setup feedback. The October r/macapps promotion policy has trust/transparency requirements and an App Pile path for unproven apps; do not assume a new repo qualifies for a main-feed post. Sources and drafts are in LAUNCH.md.

## Naming update — October 29, 2026

The public app and virtual microphone are named Local TTS Mic; the repository is `riptideiv/local-tts-mic`. Internal bundle/device identifiers and saved-data paths retain compatibility with earlier development installs. The initial public commit contains the reviewed source snapshot; local development history is retained separately.
