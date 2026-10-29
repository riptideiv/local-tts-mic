import AppKit
import AVFoundation
import Combine
import CoreAudio

@MainActor final class AppModel: ObservableObject {
    @Published var settings: Settings { didSet {
        persistSettings()
        if oldValue.volume != settings.volume { audio.setVolume(settings.volume) }
    } }
    @Published var voices: [VoiceProfile] = []
    @Published var jobs: [SpeechJob] = []
    @Published var devices: [AudioDevice] = []
    @Published var draft = ""
    @Published var engineStatus = "Starting speech engine…"
    @Published var ready = false
    @Published var error: String?
    @Published var hotkeyError: String?
    @Published var selectedPage = "Speak"
    @Published var showVoiceEditor = false
    @Published var editingVoice: VoiceProfile?
    @Published var trainingRunning = false
    @Published var showSetup = false
    @Published var setupRunning = false
    @Published var setupProgress = ""
    @Published var includeJSUT = false
    private let worker: SpeechWorking
    private let audio: AudioRouting
    private let cancellationGrace: TimeInterval
    private let playbackGrace: TimeInterval
    private let synthesisGrace: TimeInterval
    private let persistChanges: Bool
    private var generationWatchdog = UUID()
    private var currentID: String?
    private var playback = PlaybackProgress()
    private var cancelled: Set<String> = []
    private var training: Process?
    private var setupProcess: Process?
    private var setupCancelled = false
    private var deviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    var showOverlay: (() -> Void)?

    init(worker: SpeechWorking? = nil, audio: AudioRouting? = nil, startAutomatically: Bool = true, cancellationGrace: TimeInterval = 3, playbackGrace: TimeInterval = 8, synthesisGrace: TimeInterval = 90, persistChanges: Bool = true) {
        self.worker = worker ?? SpeechWorker()
        self.audio = audio ?? AudioRouter()
        self.cancellationGrace = cancellationGrace
        self.playbackGrace = playbackGrace
        self.synthesisGrace = synthesisGrace
        self.persistChanges = persistChanges
        settings = persistChanges ? (loadJSON(Settings.self, from: Paths.settings) ?? Settings()) : Settings()
        if settings.previewRoutingVersion == nil {
            // Version 1 automatically pinned preview to the built-in speakers,
            // which is wrong after switching to a headset or USB interface.
            if settings.monitorUID.isEmpty || settings.monitorUID == "BuiltInSpeakerDevice" { settings.monitorUID = AudioDevices.followSystem }
            settings.previewRoutingVersion = 1
        }
        if !FileManager.default.fileExists(atPath: Paths.settings.path),
           let benchmark = loadJSON([String: String].self, from: Paths.runtime.appendingPathComponent("engine-default.json")), let device = benchmark["device"] {
            settings.device = device
        }
        let starters = loadJSON([VoiceProfile].self, from: Paths.runtime.appendingPathComponent("starter-voices.json")) ?? []
        let saved = persistChanges ? (loadJSON([VoiceProfile].self, from: Paths.voices) ?? []) : []
        voices = starters + saved.filter { !$0.isStarter }
        if !voices.contains(where: { $0.id == settings.selectedVoice }), let first = voices.first { settings.selectedVoice = first.id }
        refreshDevices()
        self.worker.onEvent = { [weak self] in self?.handle($0) }
        deviceListener = { [weak self] _, _ in DispatchQueue.main.async { self?.refreshDevices() } }
        if let deviceListener { AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, .main, deviceListener) }
        // User files and logs never enter source control.
        if persistChanges { try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true) }
        if startAutomatically, runtimeInstalled { startEngine() }
        else if startAutomatically {
            engineStatus = "Setup needed · install the local speech runtime"
            if Paths.packaged { showSetup = true }
        }
    }

    var microphoneInstalled: Bool { devices.contains { $0.uid == AudioDevices.localMicUID && $0.outputs > 0 } }
    var runtimeInstalled: Bool { Paths.runtimeReady }

    func openDriverInstaller() {
        let installer = Paths.packaged ? Paths.source.appendingPathComponent("Local TTS Mic Driver.pkg") : Paths.root.appendingPathComponent("build/Local TTS Mic Driver.pkg")
        guard FileManager.default.fileExists(atPath: installer.path) else {
            error = "Build the microphone installer first with ./scripts/build-driver.sh from the project folder."
            return
        }
        NSWorkspace.shared.open(installer)
    }

    var selectedVoice: VoiceProfile? { voices.first { $0.id == settings.selectedVoice } }
    var queueCount: Int { jobs.filter { $0.status == "Queued" }.count }
    var busy: Bool { currentID != nil }
    var broadcastName: String { devices.first { $0.uid == settings.broadcastUID }?.name ?? "Local TTS Mic (unavailable)" }
    var monitorName: String { AudioDevices.resolveMonitor(settings.monitorUID, devices: devices)?.name ?? "Choose preview output" }

    private func persistSettings() {
        guard persistChanges else { return }
        do { try saveJSON(settings, to: Paths.settings) }
        catch { self.error = "Cannot save settings: \(error.localizedDescription)" }
    }

    func refreshDevices() {
        devices = AudioDevices.all()
        if settings.broadcastUID != AudioDevices.localMicUID { settings.broadcastUID = AudioDevices.localMicUID }
        if settings.monitorUID.isEmpty { settings.monitorUID = AudioDevices.followSystem }
        if let id = currentID, jobs.first(where: { $0.id == id })?.delivery == .broadcast, !devices.contains(where: { $0.uid == settings.broadcastUID && $0.outputs > 0 }) {
            failCurrent("The broadcast output disconnected.")
            error = "The broadcast output disconnected. Reconnect it or choose another device in Audio settings."
        }
    }

    func startEngine() {
        guard !trainingRunning, !setupRunning else { return }
        ready = false; engineStatus = "Loading GPT-SoVITS on \(settings.device.uppercased())…"
        do { try worker.start(device: settings.device) }
        catch { self.error = error.localizedDescription; engineStatus = "Setup needed"; showSetup = true }
    }

    func restartEngine() {
        stopAll(); worker.stop(); currentID = nil; cancelled.removeAll()
        startEngine()
    }

    @discardableResult func submit(text: String? = nil, delivery: Delivery = .broadcast) -> Bool {
        let value = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard value.count <= 4000 else { error = "Keep each message under 4,000 characters."; return false }
        guard ready else { error = "Wait for the speech engine to finish loading."; return false }
        guard let voice = selectedVoice else { error = "Add a voice first."; selectedPage = "Voices"; return false }
        guard queueCount < 32 else { error = "The queue is full. Wait or clear it before adding another line."; return false }
        if delivery == .broadcast, !devices.contains(where: { $0.uid == settings.broadcastUID && $0.outputs > 0 }) {
            error = "Local TTS Mic is unavailable. Install its driver and restart audio, then try again."; selectedPage = "Audio"; return false
        }
        if delivery == .preview, settings.monitorUID.isEmpty || settings.monitorUID == settings.broadcastUID {
            error = "Choose a separate preview output in Audio settings."; selectedPage = "Audio"; return false
        }
        jobs.append(SpeechJob(text: value, voice: voice, language: settings.language, speed: settings.speed, delivery: delivery,
                              monitoring: delivery == .broadcast && settings.monitoring))
        if text == nil { draft = "" }
        if jobs.count > 60, let index = jobs.firstIndex(where: { ["Done", "Stopped", "Failed"].contains($0.status) }) { jobs.remove(at: index) }
        processNext()
        return true
    }

    private func processNext() {
        guard ready, currentID == nil, let job = jobs.first(where: { $0.status == "Queued" }) else { return }
        currentID = job.id; playback = PlaybackProgress()
        Diagnostics.audio("job started id=\(job.id) delivery=\(job.delivery)")
        change(job.id) { $0.status = "Generating" }
        armGenerationWatchdog(job.id)
        do { try worker.synthesize(job) }
        catch { change(job.id) { $0.status = "Failed" }; self.error = error.localizedDescription; currentID = nil; processNext() }
    }

    private func change(_ id: String, _ update: (inout SpeechJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { update(&jobs[index]) }
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        let id = event["id"] as? String ?? ""
        if ["ready", "started", "audio", "complete", "cancelled", "error", "fatal", "exit"].contains(type) {
            Diagnostics.audio("worker event=\(type) id=\(id) pending=\(playback.pending.count)")
        }
        switch type {
        case "status": engineStatus = event["message"] as? String ?? "Loading…"
        case "ready":
            ready = true; engineStatus = "Ready · \(settings.device.uppercased()) · GPT-SoVITS"
            processNext()
        case "audio":
            guard id == currentID, !cancelled.contains(id), let job = jobs.first(where: { $0.id == id }), let path = event["path"] as? String else { return }
            let ticket = UUID()
            let now = ProcessInfo.processInfo.systemUptime
            let deadline = playback.add(ticket, seconds: event["seconds"] as? Double ?? 0, now: now, margin: playbackGrace)
            armGenerationWatchdog(id)
            change(id) { $0.status = job.delivery == .preview ? "Previewing" : "Speaking"; $0.firstAudio = event["firstAudio"] as? Double }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(playbackGrace, deadline - now)) { [weak self] in
                guard let self, self.currentID == id, self.playback.pending.contains(ticket), !self.cancelled.contains(id) else { return }
                self.failCurrent("Audio playback timed out. The next queued message will continue on a fresh output.")
            }
            do {
                var playbackSettings = settings
                playbackSettings.monitoring = job.monitoring
                try audio.play(path: path, delivery: job.delivery, settings: playbackSettings, devices: devices) { [weak self] result in
                    guard let self, self.currentID == id, !self.cancelled.contains(id), self.playback.settle(ticket) else { return }
                    switch result {
                    case .success: self.finishIfPlayed()
                    case .failure(let error): self.failCurrent(error.localizedDescription)
                    }
                }
            } catch { failCurrent(error.localizedDescription) }
        case "complete":
            guard id == currentID else { return }
            change(id) { $0.output = event["path"] as? String; $0.seconds = event["seconds"] as? Double; $0.elapsed = event["elapsed"] as? Double; $0.firstAudio = event["firstAudio"] as? Double }
            if cancelled.contains(id) { endCancelled(id) }
            else { playback.generated(); finishIfPlayed() }
        case "cancelled":
            guard id == currentID else { return }
            audio.stop()
            change(id) { if $0.status != "Failed" { $0.status = "Stopped" } }
            endCancelled(id)
        case "error":
            if id == currentID {
                audio.stop(); change(id) { if $0.status != "Stopped" { $0.status = "Failed" } }
                if !cancelled.contains(id) { error = event["message"] as? String }
                endCancelled(id)
                if settings.device == "mps" {
                    settings.device = "cpu"
                    error = "Apple GPU inference failed. Switching to CPU; you can resend the failed message."
                    restartEngine()
                }
            } else { error = event["message"] as? String }
        case "fatal", "exit":
            if settings.device == "mps" {
                settings.device = "cpu"
                engineStatus = "Apple GPU unavailable; switching to CPU…"
                worker.stop(); currentID = nil
                for index in jobs.indices where !["Done", "Stopped", "Failed"].contains(jobs[index].status) { jobs[index].status = "Failed" }
                startEngine()
                return
            }
            ready = false; engineStatus = "Engine stopped"
            audio.stop()
            for index in jobs.indices where !["Done", "Stopped", "Failed"].contains(jobs[index].status) { jobs[index].status = "Failed" }
            currentID = nil
            error = event["message"] as? String
        default: break
        }
    }

    private func armGenerationWatchdog(_ id: String) {
        let token = UUID(); generationWatchdog = token
        DispatchQueue.main.asyncAfter(deadline: .now() + synthesisGrace) { [weak self] in
            guard let self, self.currentID == id, self.generationWatchdog == token,
                  !self.playback.generationFinished, !self.cancelled.contains(id) else { return }
            self.failCurrent("The speech engine stopped responding. Recovering the queue…")
        }
    }

    private func finishIfPlayed() {
        guard playback.isFinished, let id = currentID else { return }
        audio.finishMessage()
        Diagnostics.audio("job done id=\(id)")
        change(id) { $0.status = "Done" }
        currentID = nil
        processNext()
    }

    private func endCancelled(_ id: String) {
        cancelled.remove(id)
        guard currentID == id else { return }
        Diagnostics.audio("job released id=\(id)")
        currentID = nil; playback = PlaybackProgress()
        processNext()
    }

    // A playback/device failure belongs to the active job. Preserve the backlog.
    private func failCurrent(_ message: String) {
        error = message
        guard let id = currentID else { return }
        Diagnostics.audio("job failed id=\(id) reason=\(message)")
        change(id) { $0.status = "Failed" }
        cancelCurrent()
    }

    private func cancelCurrent() {
        audio.stop()
        guard let id = currentID else { return }
        cancelled.insert(id)
        if playback.generationFinished { endCancelled(id); return }
        worker.cancel(id)
        // Inference cancellation is cooperative. Replace an unresponsive worker
        // rather than keeping the UI queue locked while waiting for an ACK.
        DispatchQueue.main.asyncAfter(deadline: .now() + cancellationGrace) { [weak self] in
            guard let self, self.currentID == id, self.cancelled.contains(id) else { return }
            Diagnostics.audio("cancel timeout; restarting worker id=\(id)")
            self.ready = false
            self.worker.stop()
            self.currentID = nil; self.cancelled.remove(id); self.playback = PlaybackProgress()
            self.startEngine()
        }
    }

    func stopAll() {
        for i in jobs.indices where jobs[i].status == "Queued" { jobs[i].status = "Stopped" }
        if let id = currentID { change(id) { $0.status = "Stopped" } }
        cancelCurrent()
    }

    func cancelQueued(_ id: String) { change(id) { if $0.status == "Queued" { $0.status = "Stopped" } } }

    func clearHistory() {
        jobs.removeAll { ["Done", "Stopped", "Failed"].contains($0.status) && $0.id != currentID }
    }

    func selectVoice(_ voice: VoiceProfile) {
        settings.selectedVoice = voice.id; settings.language = voice.language; settings.speed = voice.speed
    }

    func saveVoice(_ voice: VoiceProfile) throws {
        guard !voice.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalError("Name this voice.") }
        guard !voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalError("Enter the exact words spoken in the reference clip.") }
        let source = URL(fileURLWithPath: voice.referencePath)
        guard FileManager.default.fileExists(atPath: source.path), !source.hasDirectoryPath else { throw LocalError("Choose a reference audio file.") }
        let file = try AVAudioFile(forReading: source)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard seconds >= 3, seconds <= 10 else { throw LocalError("Reference audio must be 3–10 seconds. This clip is \(String(format: "%.1f", seconds)) seconds.") }
        let pair = [voice.gptPath ?? "", voice.sovitsPath ?? ""]
        guard pair.allSatisfy({ $0.isEmpty }) || pair.allSatisfy({ !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }) else {
            throw LocalError("Choose both existing checkpoints, or leave both empty for pretrained weights.")
        }
        var saved = voice
        let folder = Paths.support.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(voice.id).appendingPathExtension(source.pathExtension)
        if source.standardizedFileURL != target.standardizedFileURL {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
        }
        saved.referencePath = target.path
        var updated = voices
        if let i = updated.firstIndex(where: { $0.id == saved.id }) { updated[i] = saved } else { updated.append(saved) }
        try saveJSON(updated.filter { !$0.isStarter }, to: Paths.voices)
        voices = updated; selectVoice(saved)
    }

    func deleteVoice(_ id: String) {
        guard let voice = voices.first(where: { $0.id == id }), !voice.isStarter else { return }
        voices.removeAll { $0.id == id }
        try? saveJSON(voices.filter { !$0.isStarter }, to: Paths.voices)
        if settings.selectedVoice == id, let first = voices.first { selectVoice(first) }
    }

    func savePhrase() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !settings.phrases.contains(text) else { return }
        settings.phrases.append(text)
    }

    func export(_ job: SpeechJob) {
        guard let output = job.output else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Local TTS Mic.wav"
        panel.allowedContentTypes = [.wav]
        if panel.runModal() == .OK, let target = panel.url {
            do {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: output), to: target)
            } catch { self.error = error.localizedDescription }
        }
    }

    func routingTest() {
        guard !busy else { error = "Stop speech before testing the audio route."; return }
        do { try audio.testTone(settings: settings, devices: devices) }
        catch { self.error = error.localizedDescription }
    }

    func openLog() { NSWorkspace.shared.open(Paths.runtime.appendingPathComponent("logs/engine.log")) }

    func launchTraining() {
        stopAll(); worker.stop(); currentID = nil; ready = false
        let p = Process()
        p.executableURL = Paths.python
        p.arguments = [Paths.source.appendingPathComponent("engine/training.py").path, "en_US"]
        p.currentDirectoryURL = Paths.runtime.appendingPathComponent("GPT-SoVITS")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.searchPath
        env["LOCALSPEAK_ROOT"] = Paths.root.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["CUDA_VISIBLE_DEVICES"] = ""
        env["is_half"] = "False"
        env["GRADIO_SERVER_NAME"] = "127.0.0.1"
        env["GRADIO_ANALYTICS_ENABLED"] = "False"
        env["NLTK_DATA"] = Paths.runtime.appendingPathComponent("nltk_data").path
        p.environment = env
        let logURL = Paths.runtime.appendingPathComponent("logs/training.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: logURL); p.standardError = p.standardOutput
        p.terminationHandler = { [weak self] process in DispatchQueue.main.async {
            guard let self, self.training?.processIdentifier == process.processIdentifier else { return }
            self.training = nil; self.trainingRunning = false
            self.engineStatus = "Training tools closed. Restart the speech engine."
        } }
        do {
            try p.run(); training = p; trainingRunning = true; engineStatus = "Training tools running · speech paused"
            Task { [weak self] in
                let url = URL(string: "http://127.0.0.1:9874")!
                for _ in 0..<45 {
                    guard p.isRunning else { return }
                    var request = URLRequest(url: url); request.timeoutInterval = 1
                    if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                        NSWorkspace.shared.open(url); return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                self?.error = "Training tools have not become ready. Open runtime/logs/training.log to inspect the startup error."
            }
        } catch { self.error = error.localizedDescription; startEngine() }
    }

    func closeTraining() {
        training?.terminate(); training = nil; trainingRunning = false
        startEngine()
    }

    func runSetup() {
        guard !setupRunning, !trainingRunning else { return }
        stopAll(); worker.stop(); currentID = nil; ready = false
        setupRunning = true; setupCancelled = false; setupProgress = "Preparing local runtime…\n"
        let p = Process(), pipe = Pipe()
        if Paths.packaged {
            p.executableURL = Paths.python
            p.arguments = ["-u", Paths.source.appendingPathComponent("scripts/setup_packaged.py").path, "--root", Paths.root.path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [Paths.source.appendingPathComponent("scripts/setup.sh").path]
        }
        if includeJSUT { p.arguments?.append("--include-jsut") }
        do { try FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true) }
        catch { setupRunning = false; self.error = error.localizedDescription; return }
        p.currentDirectoryURL = Paths.root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.searchPath
        env["LOCALSPEAK_ROOT"] = Paths.root.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let value = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.setupProgress = String(((self?.setupProgress ?? "") + value).suffix(12000)) }
        }
        p.terminationHandler = { [weak self] process in DispatchQueue.main.async {
            guard let self else { return }
            self.setupRunning = false; self.setupProcess = nil
            if process.terminationStatus == 0 {
                let starters = loadJSON([VoiceProfile].self, from: Paths.runtime.appendingPathComponent("starter-voices.json")) ?? []
                self.voices = starters + self.voices.filter { !$0.isStarter }
                if self.selectedVoice == nil, let first = self.voices.first { self.selectVoice(first) }
                self.showSetup = false; self.startEngine()
            } else {
                self.engineStatus = self.setupCancelled ? "Setup stopped" : "Setup failed"
                self.setupProgress += self.setupCancelled
                    ? "\nDownload stopped. Click Install / repair to continue. Completed downloads are retained.\n"
                    : "\nSetup failed. Check your internet connection and available disk space, then click Install / repair to retry. Completed downloads are retained.\n"
            }
        } }
        do { try p.run(); setupProcess = p }
        catch { setupRunning = false; self.error = error.localizedDescription }
    }

    func cancelSetup() {
        guard Paths.packaged, setupRunning else { return }
        setupCancelled = true
        setupProgress += "\nStopping download…\n"
        setupProcess?.terminate()
    }

    func shutdown() {
        audio.stop(); worker.stop(); training?.terminate(); setupProcess?.terminate()
        if let deviceListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, .main, deviceListener) }
    }
}
