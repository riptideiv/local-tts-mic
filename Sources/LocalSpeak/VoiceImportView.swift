import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class VoiceImportModel: ObservableObject {
    @Published var location = ""
    @Published var inspection: VoiceImportInspection?
    @Published var name = ""
    @Published var version = ""
    @Published var language = ""
    @Published var transcript = ""
    @Published var gpt = ""
    @Published var sovits = ""
    @Published var reference = ""
    @Published var localReference: URL?
    @Published var reviewed = false
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var finished = false
    private let service = VoiceImportService()
    private var operation: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    @Published private(set) var catalogue: VoiceCatalogueEntry?

    var selection: VoiceImportSelection { VoiceImportSelection(name: name, modelVersion: version, language: language, transcript: transcript, gpt: gpt, sovits: sovits, reference: reference, localReference: localReference) }
    var canImport: Bool { inspection != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && VoiceImportRules.versions.contains(version) && ["en", "zh", "ja"].contains(language) && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && gpt.isEmpty == sovits.isEmpty && (version != "v1" || !gpt.isEmpty) && (!reference.isEmpty || localReference != nil) && reviewed && !busy }
    var selectedBytes: Int64 { inspection?.files.filter { [gpt, sovits, reference].contains($0.path) }.reduce(0) { $0 + $1.size } ?? 0 }

    func changeLocation(_ value: String) {
        location = value; inspection = nil; reviewed = false; catalogue = nil; error = nil
    }
    func inspect(entry: VoiceCatalogueEntry? = nil, folder: URL? = nil) {
        operation?.cancel(); hintTask?.cancel()
        busy = true; error = nil; inspection = nil; reviewed = false; status = "Reading voice metadata…"
        catalogue = entry
        operation = Task {
            do {
                let result: VoiceImportInspection
                if let folder { result = try await service.inspect(folder: folder) }
                else { result = try await service.inspect(repository: entry?.repository ?? location, revision: entry?.revision) }
                try Task.checkCancellation()
                if let entry {
                    for expected in entry.files {
                        guard let actual = result.files.first(where: { $0.path == expected.path }), actual.size == expected.size, actual.sha256 == expected.sha256, actual.gitSHA1 == expected.gitSHA1 else { throw LocalError("Catalogue files no longer match the pinned repository. Open the source to review the change.") }
                    }
                }
                inspection = result
                let manifest = result.manifest
                name = entry?.name ?? manifest?.name ?? result.name
                gpt = entry?.gpt ?? manifest?.gpt ?? (result.gptFiles.count == 1 ? result.gptFiles[0].path : "")
                sovits = entry?.sovits ?? manifest?.sovits ?? (result.sovitsFiles.count == 1 ? result.sovitsFiles[0].path : "")
                reference = entry?.reference ?? manifest?.reference ?? (result.audioFiles.count == 1 ? result.audioFiles[0].path : "")
                if !result.gptFiles.contains(where: { $0.path == gpt }) { gpt = "" }
                if !result.sovitsFiles.contains(where: { $0.path == sovits }) { sovits = "" }
                if !result.audioFiles.contains(where: { $0.path == reference }) { reference = "" }
                localReference = nil
                let candidates = Set(result.sovitsFiles.compactMap { VoiceImportRules.version(in: [$0.path]) })
                let guessed = VoiceImportRules.version(in: [sovits]) ?? VoiceImportRules.version(in: [gpt]) ?? (candidates.count == 1 ? candidates.first : nil)
                version = entry?.modelVersion ?? manifest?.modelVersion ?? (guessed == "unsupported" ? "" : guessed) ?? (gpt.isEmpty && sovits.isEmpty && result.gptFiles.isEmpty && result.sovitsFiles.isEmpty ? "v2ProPlus" : "")
                if !VoiceImportRules.versions.contains(version) { version = "" }
                language = entry?.language ?? VoiceImportRules.language(manifest?.language) ?? result.language ?? ""
                transcript = entry?.transcript ?? manifest?.transcript ?? ""
                if transcript.isEmpty, !reference.isEmpty, let hint = await service.referenceHint(path: reference, inspection: result) {
                    transcript = hint.transcript
                    if language.isEmpty { language = hint.language ?? "" }
                }
                busy = false; status = "Choose the files and complete any missing fields."
            } catch {
                busy = false
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { status = "Inspection stopped." } else { self.error = error.localizedDescription; status = "" }
            }
        }
    }
    func referenceChanged(_ path: String) {
        hintTask?.cancel(); reference = path; localReference = nil; transcript = ""
        guard let inspection, !path.isEmpty else { return }
        hintTask = Task {
            if let hint = await service.referenceHint(path: path, inspection: inspection), !Task.isCancelled, reference == path, transcript.isEmpty {
                transcript = hint.transcript
                if language.isEmpty { language = hint.language ?? "" }
            }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the folder containing this voice's checkpoints and reference audio."
        if panel.runModal() == .OK, let folder = panel.url { location = folder.lastPathComponent; inspect(folder: folder) }
    }
    func chooseReference() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { hintTask?.cancel(); localReference = url; reference = ""; transcript = "" }
    }
    func install(save: @escaping (VoiceProfile) throws -> Void) {
        guard let inspection, canImport else { return }
        let selected = selection, entry = catalogue
        busy = true; error = nil
        operation = Task {
            var imported: VoiceProfile?
            do {
                var profile = try await service.install(selected, inspection: inspection, support: Paths.support) { [weak self] value in
                    Task { @MainActor in self?.status = value }
                }
                if let entry, selected.gpt == entry.gpt, selected.sovits == entry.sovits, selected.reference == entry.reference, selected.localReference == nil, selected.modelVersion == entry.modelVersion { profile.catalogueID = entry.id; profile.license = entry.license }
                imported = profile
                try Task.checkCancellation()
                try save(profile)
                busy = false; finished = true
            } catch {
                if let imported { await service.discard(imported.id, support: Paths.support) }
                busy = false
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { status = "Import stopped. No voice was added." }
                else { self.error = error.localizedDescription; status = "No voice was added." }
            }
        }
    }
    func cancel() { operation?.cancel(); hintTask?.cancel() }
}

struct VoiceImportView: View {
    @ObservedObject var model: AppModel
    var entry: VoiceCatalogueEntry?
    @StateObject private var importer = VoiceImportModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showCard = false
    @State private var showFiles = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import voice").font(.title2.weight(.semibold))
            Text("Import a Hugging Face model or a downloaded folder. Checkpoints are copied into the app's voice library; the original folder can then be moved.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Hugging Face URL or owner/repository", text: Binding(get: { importer.location }, set: { importer.changeLocation($0); showFiles = true })).textFieldStyle(.roundedBorder).onSubmit { if !importer.busy { importer.inspect() } }.disabled(importer.busy)
                Button("Inspect") { importer.inspect() }.disabled(importer.busy || importer.location.isEmpty)
                Button("Choose folder…") { importer.chooseFolder() }.disabled(importer.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let inspection = importer.inspection {
                        HStack { Text("Name"); TextField("Voice name", text: $importer.name).textFieldStyle(.roundedBorder) }
                        HStack {
                            Picker("Model", selection: $importer.version) {
                                Text("Choose version").tag("")
                                ForEach(VoiceImportRules.versions, id: \.self) { Text($0).tag($0) }
                            }
                            Picker("Reference language", selection: $importer.language) {
                                Text("Choose language").tag("")
                                ForEach(["en", "zh", "ja"], id: \.self) { Text(languageLabel($0)).tag($0) }
                            }
                        }
                        DisclosureGroup("Checkpoint and reference files", isExpanded: $showFiles) {
                        filePicker("GPT checkpoint", files: inspection.gptFiles, selection: $importer.gpt, empty: "None · pretrained model")
                        filePicker("SoVITS checkpoint", files: inspection.sovitsFiles, selection: $importer.sovits, empty: "None · pretrained model")
                        Picker("Reference clip", selection: Binding(get: { importer.reference }, set: importer.referenceChanged)) {
                            Text(importer.localReference?.lastPathComponent ?? "Choose a 3–10 second clip").tag("")
                            ForEach(inspection.audioFiles) { Text($0.path).tag($0.path) }
                        }
                        HStack {
                            Button("Use my own clip…") { importer.chooseReference() }
                            if let reference = importer.localReference { Text(reference.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        }
                        Text("Exact reference transcript").font(.headline)
                        TextEditor(text: $importer.transcript).font(.body).frame(height: 72).border(.quaternary)
                        Text("Fill in any missing fields. v1 requires both checkpoints; v3/v4 checkpoints are unsupported. A repository can contain several voices or training epochs; choose a matching pair.").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text(importer.catalogue?.license ?? inspection.license).font(.callout).textSelection(.enabled)
                        HStack {
                            if let source = inspection.sourceURL { Link("Model source and terms", destination: source) }
                            if !inspection.card.isEmpty { Button(showCard ? "Hide model card" : "Read model card") { showCard.toggle() } }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: importer.selectedBytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        if showCard { Text(inspection.card).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        Text("PyTorch checkpoints can execute code when loaded. Only import a source you trust. Import reads metadata and copies files; synthesis loads the checkpoints.").font(.caption).foregroundStyle(.secondary)
                        Toggle("I trust this source and have reviewed its terms", isOn: $importer.reviewed)
                    } else if !importer.busy {
                        Text("Supported: GPT-SoVITS v1, v2, v2Pro, and v2ProPlus. Reference audio, matching .lab/.txt files, GPT-SoVITS .list transcripts, and local-tts-mic.voice.json metadata are detected when supplied.").font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).disabled(importer.busy)
            }
            if let error = importer.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if importer.busy { ProgressView().controlSize(.small) }
                Text(importer.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button(importer.busy ? "Cancel" : "Close") { if importer.busy { importer.cancel() } else { dismiss() } }
                Button(importer.inspection?.folder == nil ? "Download and import" : "Import") { importer.install { try model.saveImportedVoice($0) } }
                    .buttonStyle(.borderedProminent).disabled(!importer.canImport)
            }
        }.padding(24).frame(width: 690, height: 680).tint(.indigo)
        .interactiveDismissDisabled(importer.busy)
        .onAppear { if let entry { showFiles = false; importer.location = entry.repository; importer.inspect(entry: entry) } }
        .onChange(of: importer.finished) { _, value in if value { dismiss() } }
        .onDisappear { importer.cancel() }
    }
    private func filePicker(_ title: String, files: [VoiceImportFile], selection: Binding<String>, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: selection) {
                Text(empty).tag("")
                ForEach(files) { Text(URL(fileURLWithPath: $0.path).lastPathComponent).tag($0.path).help($0.path) }
            }
            if !selection.wrappedValue.isEmpty { Text(selection.wrappedValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }
    }
}

struct VoiceCatalogueView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Pinned community profiles. Downloads are optional and model-specific terms apply.").font(.callout).foregroundStyle(.secondary)
                ForEach(VoiceCatalogueEntry.bundled) { entry in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.headline)
                                Text("\(entry.modelVersion) · \(languageLabel(entry.language)) · \(ByteCountFormatter.string(fromByteCount: entry.totalSize, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(.indigo).accessibilityHidden(true)
                        }
                        Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                        Text("CC BY-NC-SA 4.0 · Non-commercial · Attribution and share-alike").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let voice = model.voices.first(where: { $0.catalogueID == entry.id }) {
                                Label("Installed", systemImage: "checkmark.circle").font(.caption)
                                Button("Preview") { model.previewVoice(voice) }.disabled(!model.ready)
                                Button("Use voice") { model.selectVoice(voice) }
                            } else {
                                Button("Review download…") { model.catalogueSelection = entry; model.showVoiceImporter = true }.buttonStyle(.borderedProminent)
                            }
                            Spacer()
                            Link("Reference sample", destination: entry.referenceURL)
                            Link("Source and terms", destination: entry.sourceURL)
                        }.controlSize(.small)
                    }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
                }
                Divider()
                Text("Find other community models").font(.headline)
                HStack {
                    Link("Hugging Face", destination: URL(string: "https://huggingface.co/models?search=GPT-SoVITS")!)
                    Link("AI Hobbyist", destination: URL(string: "https://www.ai-hobbyist.com/forum-138-1.html")!)
                }
                Text("Import other repositories with Import…. v3/v4 listings require a different engine and are not supported here.").font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
    }
}
