# Publishing the source preview

Release checklist for [riptideiv/local-tts-mic](https://github.com/riptideiv/local-tts-mic). Publication is performed separately from the preparation scripts.

1. Review `docs/RELEASE_REVIEW.md` and the diff against main. Run `./scripts/test.sh` and `./scripts/build.sh`; inspect signature checks. Full synthesis and real routing are separate from unit/driver tests.
2. On an Apple Silicon Mac, run setup and `python3 scripts/doctor.py`. Run `runtime/.venv/bin/python scripts/validate_engine.py --device cpu` and `runtime/.venv/bin/python scripts/validate_lifecycle.py`. Before claiming call compatibility, manually confirm received audio in the target call app.
3. Ensure only intended source/assets are tracked. `git ls-files` should contain no runtime, model weights, secrets, build outputs, or personal recordings. Keep THIRD_PARTY.md and the public-domain sample attribution.
4. Merge/review the release branch and commit the result. From a clean source tree run `python3 scripts/package-source.py`. It archives committed HEAD only, refuses private/generated paths, and writes SHA256SUMS. Inspect with `tar -tzf build/release/local-tts-mic-1.1.0-source.tar.gz`. Then enter `build/release/` and run `shasum -a 256 -c SHA256SUMS`.
5. Publish the reviewed source to `riptideiv/local-tts-mic`. Description: **Native macOS typing microphone. Local GPT-SoVITS speech, a global overlay, private preview, and a virtual mic.** Topics: `macos`, `swiftui`, `text-to-speech`, `gpt-sovits`, `local-first`, `virtual-microphone`, `accessibility`, `apple-silicon`.
6. Enable Issues and private vulnerability reporting. Confirm the LICENSE is recognized. Let Actions pass on the actual public repo before advertising green CI. Add a social preview using a real interface screenshot; avoid fake ratings, download counts, or speed claims.
7. Tag `v1.1.0` at the reviewed commit and draft a **pre-release** titled **Local TTS Mic 1.1.0 — Apple Silicon source preview**. Use CHANGELOG.md plus supported hardware, setup size, source-root dependency, ad-hoc signing, and separate voice/model terms. Attach the source archive and SHA256SUMS. Do not attach the locally built `.app` or driver package as a portable release.
8. Open the public README logged out: images, relative docs, sample audio and installation steps must resolve. Use `https://github.com/riptideiv/local-tts-mic` in any announcement.
9. Follow `docs/LAUNCH.md`, rechecking each community’s current rules immediately before posting. Owner review and actual public URLs are required. Remain available for setup failures and substantive questions.

## macOS installer development

See [macOS packaging](MACOS_PACKAGING.md) for the local app-and-driver installer, its first-run model setup, signing inputs, and validation requirements. The current package is a local test artifact and has not been attached to a GitHub release.

## Before distributing a binary

Packaged builds use a portable bundled Python runtime and per-user first-run provisioning. Obtain Developer ID identities; sign all nested code and the privileged installer; notarize/staple the app/package; verify with Gatekeeper on a clean Mac. Include notices for every redistributed component and confirm model/reference redistribution rights. Never label an ad-hoc build “notarized.” Those credentials and clean-machine validation cannot be supplied by a local source patch.
