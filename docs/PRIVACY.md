# Local data and network behavior

Normal synthesis uses a Python child process over local stdin/stdout pipes. There is no speech API account or app analytics integration. The worker sets Hugging Face/Transformers offline mode during inference. Initial setup and explicit repair contact GitHub, Hugging Face, Facebook fastText hosting, NLTK resources, and Japanese text-processing resource hosts. Those services see ordinary download requests and network metadata. Optional training/ASR tools can download further resources; their upstream dependencies have their own behavior.

| Data | Location / retention |
| --- | --- |
| Voice profiles, imported reference copies, phrases, device UIDs, shortcuts, settings | `~/Library/Application Support/Local Speak/`; retained until you remove them |
| Generated fragments and combined WAVs | `runtime/sessions/`; retained until you delete them |
| Engine, playback, training diagnostics | `runtime/logs/`; retained locally, can contain text/paths from upstream errors |
| Model files and caches | `runtime/`; retained for offline operation |
| Training UI | `127.0.0.1:9874`, sharing disabled; use only on a trusted local machine |

The visible conversation is session-only, but its audio is **not automatically erased**. Delete old session directories while the app is closed. Exports remain wherever you save them. Nothing in these runtime folders is included in source packages by the release script.

Normal operation does not record the physical microphone. Explicit loopback/queue diagnostics request input access and bind capture to the Local TTS Mic UID. Audio you send into a call is subject to the receiving app and other participants’ privacy/recording behavior.

Model checkpoints are trusted executable inputs, not inert audio files. Do not import untrusted weights. Use reference recordings you have permission to use and avoid presenting generated voices as a real speaker’s unaltered recording.

Before sharing bug reports, remove transcripts, personal filenames, device UIDs, and reference/checkpoint paths. Do not upload the runtime folder, Application Support, checkpoints, or voice recordings to a public issue.
