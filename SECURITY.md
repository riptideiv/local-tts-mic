# Security

This is an early source preview. Updates target the current main/release code; there is no long-term support branch yet.

For suspected security issues, use **GitHub → Security → Report a vulnerability** when private reporting is enabled. If it is unavailable, open an issue asking for a private contact without exploit details, private recordings, tokens, or sensitive logs. Maintainers should enable private vulnerability reporting before public launch.

Trust boundaries: imported PyTorch checkpoints can execute Python code; the microphone installer runs a narrowly scoped root postinstall to restart Core Audio; training is a local upstream WebUI bound to loopback, not a hardened multi-user service. Do not expose the training port to a network or load unknown checkpoints. The app does not auto-update or auto-install privileged components.

Setup verifies pinned upstream source and available model SHA-256 hashes. Mutable resource URLs are accepted only if their pinned content hash matches. Python package versions are pinned, but requirements.lock is not a hash-complete supply-chain lock. Dependency audits and portable, signed distribution remain release engineering work; source builds do not imply Apple notarization.
