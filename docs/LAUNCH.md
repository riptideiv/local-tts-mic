# Sharing Local TTS Mic

This document contains draft posts explaining Local TTS Mic’s workflow: **type in a floating Mac overlay and speak into a call, with local generation and a private preview button**. Describe the current Apple Silicon source preview and its tested capabilities accurately.

## Before posting

Publish the reviewed source repo and pre-release, wait for actual Actions results, and try the public instructions from a fresh checkout. Use the real screenshot and public-domain sample in `docs/assets/`. Get at least one other Mac setup report and a received-audio call test before using those as claims. The local driver harness and previous single-Mac loopback evidence are useful but are not a substitute for a call.

Current community entry points, checked October 28, 2026:

- [r/macapps rules](https://www.reddit.com/r/macapps/about/rules/) and the moderators’ [promotion policy](https://www.reddit.com/r/macapps/comments/1ryaeex/rmacapps_mods_went_too_far_whats_changing_phase_3/). The [October App Pile](https://www.reddit.com/r/macapps/comments/1wuoav5/megathread_the_app_pile_october_2026/) requires Problem / Comparison / Pricing and counts toward the promotion limit. A new source preview should use the applicable megathread unless it meets current transparency requirements. Read local-karma/account requirements; ask moderators if eligibility is unclear.
- [r/LocalLLaMA rules](https://www.reddit.com/r/LocalLLaMA/about/rules/) and [r/coolgithubprojects rules](https://www.reddit.com/r/coolgithubprojects/about/rules/) are possible technical-audience entry points. Their live eligibility is not established here; check the current rules and topic fit first. Adapt the post to the community, rather than posting identical copy everywhere.

Follow each community’s rules, disclose that you made the app, and keep replies relevant to the discussion. No post has been sent or scheduled.

## Main draft

**Title:** [OS] I built a Mac typing microphone: local GPT-SoVITS speech, a floating overlay, and private preview

I’m the developer of Local TTS Mic, a native SwiftUI/AppKit app for typing something and sending the generated voice into a call or game.

Control–Option–Space opens a small overlay, Enter queues the line, and a dedicated virtual microphone carries the speech. Preview stays in your headphones; “Hear while speaking” lets you monitor a sent line too. It uses GPT-SoVITS locally after a one-time model download, without an account or speech API key.

It’s an early **Apple Silicon source preview**. You need macOS 14+, Swift 6+, uv, FFmpeg, and several GB of model/dependency downloads. The app is built locally and tied to that source folder; it is not a notarized drag-and-drop download. The optional virtual mic installer needs admin access and briefly restarts system audio. English/Mandarin examples are included in setup; Japanese supports your own reference, with a restricted JSUT example as an opt-in.

I’m looking for setup feedback from other Macs and received-audio reports from call apps. CPU is the default; speech has sentence-generation latency, and MPS is experimental. The repository records the actual tests and known limits.

Source, setup, screenshot, and audio sample: [riptideiv/local-tts-mic](https://github.com/riptideiv/local-tts-mic).

The app code is MIT; models and reference voices have separate terms. If you try it, please tell me your Mac chip/RAM, macOS version, whether Preview worked, and which call app you tested.

## Short Problem / Comparison / Pricing draft

**Local TTS Mic — native Mac typing microphone** (attach the real screenshot)

**Problem:** Type a line from an overlay while in a call/game, then send local synthetic speech through a virtual microphone. Private preview, saved phrases, and queue are built in. I’m the developer.

**Comparison:** GPT-SoVITS’s own WebUI provides model/training controls; Local TTS Mic wraps that engine in a native typing overlay and call-oriented routing. The upstream WebUI is the better starting point for broader model experimentation. Local TTS Mic adds local setup and a driver, so this preview is for people comfortable building from source.

**Pricing:** $0 app source, MIT; no app subscription or speech API fee. You supply the Mac, storage, and setup bandwidth. Models/reference recordings have separate terms. Apple Silicon only, macOS 14+, source build, no notarized binary. [riptideiv/local-tts-mic](https://github.com/riptideiv/local-tts-mic).

## Demo and follow-through

Use `docs/DEMO.md` to reproduce the screenshot and sample, or record a real 15–25 second clip: open overlay → type → submit → show received audio meter → stop → private preview with the input meter silent. Capture only permitted reference voices and redact account names/notifications. Do not claim a static screenshot is a live call recording.

Launch in one suitable community first. Answer setup questions while the post is active, fix reproducible blockers, and link fixes in the original thread when relevant. Submit elsewhere only if that community permits it and you can offer relevant technical detail. Open focused, reproducible issues for early contributors.

Use setup reports and call-app compatibility feedback to prioritize fixes. Document reproducible issues and update the installation guidance when a fix is available.
