import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let accent = Color.indigo

struct MainView: View {
    @ObservedObject var model: AppModel
    private let pages = [("Speak", "text.bubble"), ("Voices", "person.wave.2"), ("Phrases", "bookmark"), ("Audio", "slider.horizontal.3")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
                    Text("Local TTS Mic").font(.system(size: 18, weight: .semibold))
                }.padding(.top, 14)
                VStack(spacing: 6) {
                    ForEach(pages, id: \.0) { page in
                        Button { model.selectedPage = page.0 } label: {
                            Label(page.0, systemImage: page.1).font(.system(size: 14, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                                .background(model.selectedPage == page.0 ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(model.selectedPage == page.0 ? accent : .primary)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label("Runs on your Mac", systemImage: "desktopcomputer").font(.system(size: 12, weight: .medium))
                    Text("GPT-SoVITS\nNo account. No cloud speech.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    Button("Open engine log") { model.openLog() }.buttonStyle(.link).font(.system(size: 11))
                }.padding(.bottom, 12)
            }.padding(.horizontal, 18).frame(width: 180).frame(maxHeight: .infinity).background(.quaternary.opacity(0.45))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.selectedPage == "Speak" ? "Text to speech" : model.selectedPage).font(.system(size: 27, weight: .semibold))
                        HStack(spacing: 6) {
                            Circle().fill(model.ready ? Color.green : Color.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(model.engineStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { model.showOverlay?() } label: {
                        VStack(alignment: .trailing, spacing: 3) {
                            Label("Type anywhere", systemImage: "rectangle.on.rectangle")
                            Text(model.settings.overlayHotkey.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.borderless).help("Open the typing overlay")
                }.padding(26)
                Divider()
                Group {
                    switch model.selectedPage {
                    case "Voices": VoicesView(model: model)
                    case "Phrases": PhrasesView(model: model)
                    case "Audio": AudioSettingsView(model: model)
                    default:
                        if !model.runtimeInstalled || model.voices.isEmpty {
                            // First-run guidance adds height; keep all controls
                            // reachable in the supported minimum window size.
                            ScrollView { SpeakView(model: model) }
                        } else { SpeakView(model: model) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Local TTS Mic", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showVoiceEditor) { VoiceEditor(model: model, existing: model.editingVoice) }
        .sheet(isPresented: $model.showSetup) { SetupView(model: model) }
    }
}

struct VoiceControls: View {
    @ObservedObject var model: AppModel
    var compact = false
    var body: some View {
        HStack(spacing: 12) {
            Picker("Voice", selection: $model.settings.selectedVoice) {
                if model.voices.isEmpty { Text("Set up voices first").tag(model.settings.selectedVoice) }
                ForEach(model.voices) { Text($0.name).tag($0.id) }
            }.disabled(model.voices.isEmpty).labelsHidden().frame(maxWidth: compact ? 200 : 240).accessibilityLabel("Voice")
                .onChange(of: model.settings.selectedVoice) {
                    if let voice = model.selectedVoice { model.settings.language = voice.language; model.settings.speed = voice.speed }
                }
            Picker("Language", selection: $model.settings.language) {
                ForEach(["en", "zh", "ja", "auto"], id: \.self) { Text(languageLabel($0)).tag($0) }
            }.labelsHidden().frame(width: compact ? 130 : 150).accessibilityLabel("Language")
            if !compact {
                Spacer()
                Text("\(model.settings.speed, specifier: "%.2g")×").font(.system(size: 12)).monospacedDigit().frame(width: 32)
                Slider(value: $model.settings.speed, in: 0.5...2, step: 0.05).frame(width: 85).accessibilityLabel("Speech speed")
            }
        }
    }
}

struct SpeakView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.runtimeInstalled || model.voices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Start with your first private preview", systemImage: "sparkles").font(.headline)
                    Text("Install the speech runtime and example voices once, then type a sentence and choose Preview. No microphone driver is needed to try it.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Set up local speech…") { model.showSetup = true }.buttonStyle(.borderedProminent)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            } else if !model.microphoneInstalled {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "mic.badge.plus").foregroundStyle(accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Preview is ready to try. Calls need Local TTS Mic.").font(.callout.weight(.medium))
                        Text("Install the driver from Audio settings, then select it in your call app.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set up mic") { model.selectedPage = "Audio" }
                }.padding(14).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            VoiceControls(model: model)
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty { Text("What would you like to say?").font(.system(size: 22)).foregroundStyle(.tertiary).padding(.horizontal, 17).padding(.top, 14).allowsHitTesting(false) }
                    ComposerInput(text: $model.draft, onSubmit: { model.submit() }).frame(minHeight: 105, maxHeight: 175)
                }
                HStack {
                    Text(model.settings.monitoring ? "Enter to speak + preview · Shift–Enter for a new line" : "Enter to speak · Shift–Enter for a new line").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.draft.count)/4000").font(.system(size: 11)).foregroundStyle(model.draft.count > 4000 ? .red : .secondary).monospacedDigit()
                }.padding(.horizontal, 16).padding(.bottom, 14)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
            HStack(spacing: 10) {
                Button { model.submit() } label: { Label(model.settings.monitoring ? "Speak + preview" : "Speak", systemImage: "waveform").frame(minWidth: 100) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.ready || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { model.submit(delivery: .preview) } label: { Label("Preview", systemImage: "headphones") }.controlSize(.large).disabled(!model.ready || model.draft.isEmpty)
                Button { model.savePhrase() } label: { Image(systemName: "bookmark") }.help("Save this draft as a phrase").accessibilityLabel("Save phrase").controlSize(.large).disabled(model.draft.isEmpty)
                Spacer()
                Button { model.stopAll() } label: { Label("Stop / clear", systemImage: "stop.fill") }.controlSize(.large).disabled(!model.busy && model.queueCount == 0)
            }
            HStack {
                SpeechMonitorToggle(model: model)
                Spacer()
                if model.settings.monitoring {
                    Text(model.monitorName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.font(.system(size: 12))
            HStack(spacing: 6) {
                Image(systemName: "mic").foregroundStyle(accent).accessibilityHidden(true)
                Text("Speaking to \(model.broadcastName)")
                Spacer()
                Button("Change") { model.selectedPage = "Audio" }.buttonStyle(.link)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Conversation").font(.system(size: 14, weight: .semibold))
                if model.queueCount > 0 { Text("\(model.queueCount) queued").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button("Clear history") { model.clearHistory() }.buttonStyle(.link).font(.system(size: 11))
            }
            if model.jobs.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "text.bubble").font(.system(size: 27)).foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text("Say something when you’re ready.").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Generated speech appears here. Preview stays private.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs.reversed()) { job in
                            JobRow(model: model, job: job)
                            Divider().padding(.vertical, 10)
                        }
                    }
                }
            }
        }.padding(26)
    }
}

struct SpeechMonitorToggle: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Toggle("Hear while speaking", isOn: $model.settings.monitoring)
            .toggleStyle(.checkbox)
            .help("New messages play through your preview output while being sent to the microphone. Preview stays private.")
            .accessibilityHint("When on, Enter sends speech to the microphone and plays it through your preview output.")
    }
}

struct JobRow: View {
    @ObservedObject var model: AppModel
    let job: SpeechJob
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: job.delivery == .preview ? "headphones" : "waveform").foregroundStyle(accent.opacity(0.8)).frame(width: 22).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(job.voice.name)
                    Text(job.status).foregroundStyle(job.status == "Failed" ? Color.red : Color.secondary)
                    if job.monitoring { Text("Speak + preview") }
                    if let first = job.firstAudio { Text("First audio \(first, specifier: "%.1f")s").monospacedDigit() }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if job.status == "Queued" {
                Button { model.cancelQueued(job.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from queue").accessibilityLabel("Remove queued message")
            }
            if job.output != nil {
                Button { model.export(job) } label: { Image(systemName: "square.and.arrow.down") }.buttonStyle(.borderless).help("Export WAV").accessibilityLabel("Export speech as WAV")
            }
        }
    }
}

struct OverlayView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(accent).accessibilityHidden(true)
                VoiceControls(model: model, compact: true)
                Spacer()
                Button { model.stopAll() } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("Stop speech").accessibilityLabel("Stop speech")
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss typing overlay")
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty { Text("Type a line…").font(.system(size: 19)).foregroundStyle(.tertiary).padding(.leading, 17).padding(.top, 14).allowsHitTesting(false) }
                ComposerInput(text: $model.draft, compact: true, onSubmit: { if model.submit() { dismiss() } }, onDismiss: dismiss)
            }.frame(height: 86).background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(model.error ?? (model.ready ? "\(model.broadcastName) · Enter to \(model.settings.monitoring ? "speak + preview" : "speak")" : model.engineStatus))
                    .foregroundStyle(model.error == nil ? Color.secondary : Color.red).lineLimit(1)
                Spacer()
                if model.queueCount > 0 { Text("\(model.queueCount) queued") }
                SpeechMonitorToggle(model: model)
                Text("Esc to close")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).tint(accent)
    }
}

struct VoicesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Start with an example, then bring your own voice.").foregroundStyle(.secondary)
                    Spacer()
                    Button { model.editingVoice = nil; model.showVoiceEditor = true } label: { Label("Add voice", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }
                ForEach(model.voices) { voice in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "person.crop.circle").font(.system(size: 28)).foregroundStyle(accent).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(voice.name).font(.system(size: 17, weight: .semibold))
                                Text("\(voice.languageName) · \(voice.modelVersion) · \(voice.gptPath == nil ? "Reference voice" : "Custom checkpoints")").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.settings.selectedVoice == voice.id { Label("Selected", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(accent) }
                        }
                        Text(voice.transcript).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        HStack {
                            Button("Use voice") { model.selectVoice(voice) }
                            Button("Preview") {
                                model.selectVoice(voice)
                                let text = ["en": "Hello! This is my local voice.", "zh": "你好，这是在本地生成的语音。", "ja": "こんにちは。これはローカルで生成した音声です。"]
                                model.submit(text: text[voice.language] ?? text["en"]!, delivery: .preview)
                            }.disabled(!model.ready)
                            Button(voice.isStarter ? "Duplicate / edit" : "Edit") {
                                var editable = voice
                                if voice.isStarter { editable.id = UUID().uuidString; editable.name += " copy" }
                                model.editingVoice = editable; model.showVoiceEditor = true
                            }
                            Spacer()
                            if !voice.isStarter { Button("Delete", role: .destructive) { model.deleteVoice(voice.id) }.buttonStyle(.borderless) }
                        }.controlSize(.small)
                        if let license = voice.license { Text(license).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
                }
                Divider().padding(.vertical, 8)
                Text("Train a custom voice later").font(.headline)
                Text("Open the local GPT-SoVITS tools to prepare recordings, correct transcripts, and train on CPU. Speech pauses while the tools are running. Import the resulting GPT and SoVITS checkpoints with Add voice.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    if model.trainingRunning {
                        Button("Open training browser") { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:9874")!) }
                        Button("Close tools and resume speech") { model.closeTraining() }
                    } else {
                        Button("Open training tools") { model.launchTraining() }.disabled(!model.ready)
                    }
                    Button("Training guide") { NSWorkspace.shared.open(Paths.root.appendingPathComponent("TRAINING.md")) }
                }
            }.padding(26)
        }
    }
}

struct PhrasesView: View {
    @ObservedObject var model: AppModel
    @State private var phrase = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keep the things you say often within reach.").foregroundStyle(.secondary)
            HStack {
                TextField("New phrase", text: $phrase).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.settings.phrases.enumerated()), id: \.offset) { index, phrase in
                        HStack(spacing: 12) {
                            Text(phrase).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Edit in composer") { model.draft = phrase; model.selectedPage = "Speak" }
                            Button { model.submit(text: phrase) } label: { Image(systemName: "play.fill") }.disabled(!model.ready).help("Speak phrase").accessibilityLabel("Speak saved phrase")
                            Button { model.settings.phrases.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete phrase").accessibilityLabel("Delete saved phrase")
                        }.padding(.vertical, 15)
                        Divider()
                    }
                }
            }
        }.padding(26)
    }
    private func add() {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !model.settings.phrases.contains(text) { model.settings.phrases.append(text); phrase = "" }
    }
}

struct AudioSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            Form {
                Section("Virtual microphone") {
                    LabeledContent("Microphone", value: model.broadcastName)
                    if !model.microphoneInstalled {
                        Button("Install Local TTS Mic…") { model.openDriverInstaller() }
                        Text("The installer asks for administrator access and briefly restarts all Mac audio. Finish any calls first. Private preview works without this driver.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("In Discord, Zoom, a game, or a meeting app, choose Local TTS Mic as the microphone input. Your Mac’s system output stays unchanged.").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button("Send test tone") { model.routingTest() }.disabled(model.busy)
                        Button("Refresh devices") { model.refreshDevices() }
                        Button("Audio MIDI Setup") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")) }
                    }
                }
                Section("Private preview and monitoring") {
                    Picker("Preview output", selection: $model.settings.monitorUID) {
                        Text("System output (\(model.devices.first { $0.id == AudioDevices.defaultOutputID() }?.name ?? "default"))").tag(AudioDevices.followSystem)
                        Text("Choose output").tag("")
                        if !model.settings.monitorUID.isEmpty, model.settings.monitorUID != AudioDevices.followSystem, !model.devices.contains(where: { $0.uid == model.settings.monitorUID }) { Text("Unavailable device").tag(model.settings.monitorUID) }
                        ForEach(model.devices.filter { $0.outputs > 0 && $0.uid != model.settings.broadcastUID }) { Text($0.name).tag($0.uid) }
                    }.onChange(of: model.settings.monitorUID) { model.stopAll() }
                    SpeechMonitorToggle(model: model)
                    HStack {
                        Text("Speech volume")
                        Slider(value: $model.settings.volume, in: 0...1)
                        Text("\(Int(model.settings.volume * 100))%").monospacedDigit().frame(width: 40)
                    }
                    Text("Preview always uses this output only. Use headphones if you want to keep the room quiet.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Section("Keyboard shortcuts") {
                    HStack { Text("Typing overlay"); Spacer(); ShortcutRecorder(shortcut: $model.settings.overlayHotkey).frame(width: 170, height: 26) }
                    HStack { Text("Stop and clear queue"); Spacer(); ShortcutRecorder(shortcut: $model.settings.stopHotkey).frame(width: 170, height: 26) }
                    if let error = model.hotkeyError { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
                    Text("Click a shortcut to record a new combination. Include Control, Option, or Command.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Section("Local engine") {
                    Picker("Processor", selection: $model.settings.device) { Text("CPU · reliable").tag("cpu"); Text("Apple GPU · MPS").tag("mps") }
                    HStack {
                        Button("Restart engine") { model.restartEngine() }.disabled(model.trainingRunning || model.setupRunning)
                        Button("Open engine log") { model.openLog() }
                        Button("Setup / repair runtime") { model.showSetup = true }
                    }
                    Text("Changing processor takes effect after restarting. MPS performance varies by model and text. Choose CPU if GPU inference fails.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).padding(8)
        }
    }
}

struct VoiceEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var voice: VoiceProfile
    @State private var error: String?
    init(model: AppModel, existing: VoiceProfile?) {
        self.model = model
        _voice = State(initialValue: existing ?? VoiceProfile(name: "", referencePath: "", transcript: "", language: "en"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(voice.name.isEmpty ? "Add" : "Edit") voice").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $voice.name)
                Picker("Reference language", selection: $voice.language) { ForEach(["en", "zh", "ja"], id: \.self) { Text(languageLabel($0)).tag($0) } }
                HStack {
                    Text("Reference clip")
                    Spacer()
                    Text(voice.referencePath.isEmpty ? "3–10 seconds of clean speech" : URL(fileURLWithPath: voice.referencePath).lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    Button("Choose…") { chooseAudio() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exact transcript")
                    TextEditor(text: $voice.transcript).font(.body).frame(height: 100).border(.quaternary)
                }
                Picker("Model version", selection: $voice.modelVersion) { ForEach(["v2ProPlus", "v2Pro", "v2"], id: \.self) { Text($0).tag($0) } }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Custom checkpoints (optional)").font(.headline)
                    Text("Leave both empty for the pretrained model. Imported checkpoints must match the model version above. Only open model files you trust.").font(.system(size: 11)).foregroundStyle(.secondary)
                    checkpointRow("GPT", path: $voice.gptPath)
                    checkpointRow("SoVITS", path: $voice.sovitsPath)
                    Button("Use pretrained weights") { voice.gptPath = nil; voice.sovitsPath = nil }
                }.padding(.top, 8)
            }.textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save voice") {
                    do { try model.saveVoice(voice); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 550).tint(accent)
    }
    private func checkpointRow(_ title: String, path: Binding<String?>) -> some View {
        HStack {
            Text(title).frame(width: 55, alignment: .leading)
            Text(path.wrappedValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Pretrained").lineLimit(1).foregroundStyle(.secondary)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                panel.allowedContentTypes = [UTType(filenameExtension: title == "GPT" ? "ckpt" : "pth") ?? .data]
                if panel.runModal() == .OK { path.wrappedValue = panel.url?.path }
            }
        }
    }
    private func chooseAudio() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK { voice.referencePath = panel.url?.path ?? "" }
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Local speech setup").font(.title2.weight(.semibold))
            Text("Install the isolated Python runtime, pretrained models, and English and Mandarin reference voices. Allow at least 10 GB free for setup and temporary files. Downloads can take a while; once ready, speech runs offline.").font(.system(size: 13)).foregroundStyle(.secondary)
            Toggle("Also install the Japanese JSUT reference voice", isOn: $model.includeJSUT).disabled(model.setupRunning)
            Text("JSUT audio permits personal use and non-commercial research. Commercial use requires permission. You can also add your own Japanese recording.").font(.caption).foregroundStyle(.secondary)
            Link("Read JSUT terms", destination: URL(string: "https://sites.google.com/site/shinnosuketakamichi/publication/jsut")!)
            if model.setupRunning { ProgressView().controlSize(.small) }
            ScrollView {
                Text(model.setupProgress.isEmpty ? "First install Command Line Tools (xcode-select --install), then uv and FFmpeg (brew install uv ffmpeg). Setup downloads from GitHub, Hugging Face, and upstream resource hosts." : model.setupProgress)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).frame(height: 240).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Close") { dismiss() }.disabled(model.setupRunning)
                Button("Install / repair") { model.runSetup() }.buttonStyle(.borderedProminent).disabled(model.setupRunning || model.trainingRunning)
            }
        }.padding(26).frame(width: 570).interactiveDismissDisabled(model.setupRunning)
    }
}
