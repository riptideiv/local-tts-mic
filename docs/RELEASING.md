# Releasing

Release procedure for [riptideiv/local-tts-mic](https://github.com/riptideiv/local-tts-mic). Builders create local artifacts; publication is a separate, explicit operation.

1. Merge reviewed feature PRs. Update `VERSION`, CHANGELOG.md, installation documentation, and download links on a release branch. Keep version numbers in the app, installer receipts, release tag, and asset names consistent.
2. Run the model-free tests, native build, driver harness/sanitizers, source hygiene checks, and signature verification. Let GitHub Actions pass on the exact release source. Record real synthesis, model switching, routing, and installed-Mac tests separately from unit coverage.
3. Keep models, private recordings, local settings, logs, caches, and secrets out of Git. Preserve LICENSE and THIRD_PARTY.md; inspect bundled dependency notices. Community models/references are downloaded or imported separately, with their own terms.
4. From a clean release checkout, run `python3 scripts/package-macos.py` (or the signed command below) and `python3 scripts/package-source.py`. The source packager archives committed HEAD and rejects private/generated paths. Inspect/extract both outputs. Confirm bundle version, architecture/OS checks, portable runtime paths, source/worker contents, and code seal. Exercise the extracted app with isolated test data; this does not replace an installed-Mac test.
5. Assemble the `.pkg`, `local-tts-mic-<version>-source.tar.gz`, and one `SHA256SUMS` covering both artifacts. Verify checksums before upload. Prepare release notes with platform requirements, first-run download/storage needs, the driver audio restart, signing status, supported checkpoint versions, and known limitations.
6. Tag the exact release source and create a draft GitHub release. Upload only the reviewed artifacts, verify their remote names/sizes/digests, then publish. Do not overwrite an existing release/tag with different source or silently replace a published binary. A correction gets a new version.
7. Open the public README/release page and verify download links, images, documentation, and assets. Announcements are separate from publication and require their own authorization.

## Current binary preview

Version 1.2.0 is an **unsigned, unnotarized preview** for Apple Silicon on macOS 15+. It must be labelled accordingly in the asset filename, release notes, and installation docs. The app has an ad-hoc code seal; the installer has no Developer ID Installer signature. Do not call it notarized, Gatekeeper-verified, or certified on clean Macs. The preceding installer was reported working by the owner; broader fresh setup, memory, call-app, and uninstall/upgrade testing remains pending.

The 1.1.0 release remains the earlier source-only preview. Do not attach the new installer to that older source tag.

## Signed distribution

A Developer ID Application identity and Developer ID Installer identity are required for the signed path. Apple Development identities are not substitutes. The notarization Keychain profile must already exist:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: …'
export DEVELOPER_ID_INSTALLER='Developer ID Installer: …'
python3 scripts/package-macos.py --sign --notarize local-tts-mic
```

See [macOS packaging](MACOS_PACKAGING.md) for nested signing, portability checks, embedded driver repair packages, notarization/stapling, and clean-Mac validation. An unsigned preview does not establish those signed-distribution checks.
