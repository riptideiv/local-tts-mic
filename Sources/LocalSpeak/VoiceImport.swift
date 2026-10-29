import Foundation
import AVFoundation
import CryptoKit

struct VoiceImportFile: Identifiable, Codable, Hashable {
    var path: String
    var size: Int64
    var sha256: String?
    var gitSHA1: String?
    var id: String { path }
    var ext: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    var isAudio: Bool { ["wav", "flac", "mp3", "m4a", "aiff", "aif"].contains(ext) }
}

struct VoiceImportManifest: Codable {
    var name: String?
    var modelVersion: String?
    var language: String?
    var transcript: String?
    var reference: String?
    var gpt: String?
    var sovits: String?
    var license: String?
}

struct VoiceReferenceHint {
    var transcript: String
    var language: String?
}

struct VoiceImportInspection {
    var name: String
    var sourceURL: URL?
    var repository: String?
    var revision: String?
    var folder: URL?
    var files: [VoiceImportFile]
    var license: String
    var card: String
    var language: String?
    var manifest: VoiceImportManifest?
    var hints: [String: VoiceReferenceHint] = [:]
    var gptFiles: [VoiceImportFile] { files.filter { $0.ext == "ckpt" } }
    var sovitsFiles: [VoiceImportFile] { files.filter { $0.ext == "pth" } }
    var audioFiles: [VoiceImportFile] { files.filter(\.isAudio) }
}

struct VoiceCatalogueEntry: Codable, Identifiable {
    var id: String
    var name: String
    var summary: String
    var repository: String
    var revision: String
    var modelVersion: String
    var language: String
    var transcript: String
    var reference: String
    var gpt: String
    var sovits: String
    var license: String
    var files: [VoiceImportFile]
    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)/tree/\(revision)")! }
    var referenceURL: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/")!.appendingPathComponent(reference) }
    static var bundled: [VoiceCatalogueEntry] {
        loadJSON([VoiceCatalogueEntry].self, from: Paths.source.appendingPathComponent("resources/voice-catalogue.json")) ?? []
    }
}

struct VoiceImportSelection {
    var name: String
    var modelVersion: String
    var language: String
    var transcript: String
    var gpt: String
    var sovits: String
    var reference: String
    var localReference: URL?
}

enum VoiceImportRules {
    static let versions = ["v2", "v2Pro", "v2ProPlus"]
    static func relativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count < 2048 && !path.contains("\\") && !path.contains("\0") && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func repository(_ text: String) throws -> (id: String, revision: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = value.contains("://") ? value : "https://huggingface.co/" + value
        guard let url = URL(string: candidate), url.scheme == "https", url.host?.lowercased() == "huggingface.co", url.user == nil, url.password == nil, url.port == nil else {
            throw LocalError("Enter a Hugging Face model repository URL, or owner/repository.")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        let valid: (String) -> Bool = { $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil }
        guard parts.count >= 2, valid(parts[0]), valid(parts[1]), !["datasets", "spaces", "models"].contains(parts[0]) else { throw LocalError("Choose a model repository, not a search, dataset, or Space URL.") }
        var revision: String?
        if parts.count > 2 {
            guard parts.count >= 4, ["tree", "blob", "resolve"].contains(parts[2]), valid(parts[3]) else { throw LocalError("Use the repository's main URL or a tree URL with its revision.") }
            revision = parts[3]
        }
        return (parts[0] + "/" + parts[1], revision)
    }
    static func version(in paths: [String]) -> String? {
        let components = paths.flatMap { $0.lowercased().split(separator: "/").map(String.init) }
        // Directory names describe architecture; filenames often contain a creator's unrelated v1/v3 release number.
        for (key, result) in [("v2proplus", "v2ProPlus"), ("v2pro", "v2Pro"), ("v2", "v2"), ("v4", "unsupported"), ("v3", "unsupported"), ("v1", "unsupported")] {
            if components.contains(where: { $0 == key || $0 == "gpt_weights_" + key || $0 == "sovits_weights_" + key }) { return result }
        }
        return nil
    }
    static func language(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "en", "english": return "en"
        case "zh", "zh-cn", "chinese", "中文": return "zh"
        case "ja", "jp", "japanese", "日本語": return "ja"
        default: return nil
        }
    }
    static func listHints(_ text: String, files: [VoiceImportFile]) -> [String: VoiceReferenceHint] {
        var hints: [String: VoiceReferenceHint] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[3].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let name = fields[0].replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
            let matches = files.filter { $0.isAudio && URL(fileURLWithPath: $0.path).lastPathComponent == name }
            if matches.count == 1 { hints[matches[0].path] = VoiceReferenceHint(transcript: fields[3], language: language(fields[2])) }
        }
        return hints
    }
    static func sovitsVersion(_ url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let header = String(decoding: try file.read(upToCount: 2) ?? Data(), as: UTF8.self)
        return ["03": "unsupported", "04": "unsupported", "05": "v2Pro", "06": "v2ProPlus", "07": "unsupported", "08": "unsupported"][header]
    }
    static func verify(_ url: URL, file: VoiceImportFile) throws {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw LocalError("Imported voice assets must be regular files, not links.") }
        let size = attributes.fileSize ?? 0
        guard Int64(size) == file.size else { throw LocalError("Incomplete file: \(file.path). Retry the import.") }
        var sha = SHA256(), git = Insecure.SHA1()
        git.update(data: Data("blob \(size)\0".utf8))
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { sha.update(data: block); git.update(data: block) }
        if let expected = file.sha256, sha.finalize().map({ String(format: "%02x", $0) }).joined() != expected { throw LocalError("Checksum mismatch: \(file.path). No voice was installed.") }
        if file.sha256 == nil, let expected = file.gitSHA1, git.finalize().map({ String(format: "%02x", $0) }).joined() != expected { throw LocalError("Repository file changed: \(file.path). No voice was installed.") }
    }
}

actor VoiceImportService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    private struct HubMetadata: Decodable {
        var sha: String
        var siblings: [Sibling]
        struct Sibling: Decodable {
            var rfilename: String
            var size: Int64?
            var blobId: String?
            var lfs: LFS?
            struct LFS: Decodable { var sha256: String; var size: Int64 }
        }
    }
    private func url(_ repository: String, revision: String, path: String? = nil) throws -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        let suffix = path.map { "/resolve/" + revision + "/" + $0.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/") } ?? ""
        guard let url = URL(string: "https://huggingface.co/" + repository + suffix) else { throw LocalError("Invalid repository file path.") }
        return url
    }
    private func data(_ url: URL, limit: Int = 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 60
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
            throw LocalError("Cannot read this public repository. Private or gated models need to be downloaded separately, then imported from a folder.")
        }
        guard data.count <= limit else { throw LocalError("Repository metadata is too large. Choose a smaller voice folder.") }
        return data
    }
    private func text(_ file: VoiceImportFile, inspection: VoiceImportInspection) async throws -> String {
        guard file.size <= 1024 * 1024 else { throw LocalError("Metadata file is too large.") }
        let bytes: Data
        if let folder = inspection.folder { bytes = try Data(contentsOf: localFile(file.path, folder: folder)) }
        else { bytes = try await data(url(inspection.repository!, revision: inspection.revision!, path: file.path)) }
        return String(decoding: bytes, as: UTF8.self)
    }
    func inspect(repository text: String, revision pinned: String? = nil) async throws -> VoiceImportInspection {
        let parsed = try VoiceImportRules.repository(text)
        let revision = pinned ?? parsed.revision
        let revisionPart = revision.map { "/revision/" + $0 } ?? ""
        let api = URL(string: "https://huggingface.co/api/models/\(parsed.id)\(revisionPart)?blobs=true")!
        let bytes = try await data(api, limit: 8 * 1024 * 1024)
        let metadata = try JSONDecoder().decode(HubMetadata.self, from: bytes)
        guard metadata.sha.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else { throw LocalError("Repository did not return an immutable revision.") }
        if let pinned, metadata.sha != pinned { throw LocalError("Repository revision does not match the pinned catalogue entry.") }
        guard metadata.siblings.count <= 5000 else { throw LocalError("This repository has too many files. Download the voice's folder and import that folder.") }
        let files = metadata.siblings.compactMap { value -> VoiceImportFile? in
            guard VoiceImportRules.relativePath(value.rfilename), let size = value.size ?? value.lfs?.size, size >= 0 else { return nil }
            return VoiceImportFile(path: value.rfilename, size: size, sha256: value.lfs?.sha256, gitSHA1: value.blobId)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let card = object?["cardData"] as? [String: Any]
        let languages = card?["language"] as? [String] ?? (card?["language"] as? String).map { [$0] } ?? []
        let language = languages.count == 1 ? VoiceImportRules.language(languages[0]) : nil
        var result = VoiceImportInspection(name: parsed.id.split(separator: "/").last.map(String.init) ?? parsed.id,
            sourceURL: try url(parsed.id, revision: metadata.sha), repository: parsed.id, revision: metadata.sha,
            files: files, license: card?["license"] as? String ?? "No license identifier supplied. Read the model card.", card: "", language: language)
        result.sourceURL = URL(string: "https://huggingface.co/\(parsed.id)/tree/\(metadata.sha)")
        if let readme = files.first(where: { $0.path.lowercased() == "readme.md" && $0.size <= 1024 * 1024 }) { result.card = (try? await self.text(readme, inspection: result)) ?? "Open the source to read its model card." }
        return try await fillHints(result)
    }
    func inspect(folder: URL) async throws -> VoiceImportInspection {
        let folder = folder.resolvingSymlinksInPath()
        let files = try folderFiles(folder)
        var result = VoiceImportInspection(name: folder.lastPathComponent, folder: folder, files: files,
            license: "Check the files and the model's original terms.", card: "", language: nil)
        if let readme = files.first(where: { $0.path.lowercased() == "readme.md" && $0.size <= 1024 * 1024 }) { result.card = try await text(readme, inspection: result) }
        return try await fillHints(result)
    }
    private func folderFiles(_ folder: URL) throws -> [VoiceImportFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw LocalError("Cannot read this folder.") }
        var files: [VoiceImportFile] = [], visited = 0
        for case let item as URL in enumerator {
            visited += 1
            guard visited <= 10000 else { throw LocalError("Choose the voice's own folder, not a whole model library.") }
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolved = item.resolvingSymlinksInPath()
            let base = folder.resolvingSymlinksInPath().pathComponents
            guard resolved.pathComponents.starts(with: base) else { continue }
            let path = resolved.pathComponents.dropFirst(base.count).joined(separator: "/")
            guard VoiceImportRules.relativePath(path) else { continue }
            files.append(VoiceImportFile(path: path, size: Int64(values.fileSize ?? 0)))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    private func fillHints(_ input: VoiceImportInspection) async throws -> VoiceImportInspection {
        var result = input
        if let file = result.files.first(where: { ["local-tts-mic.voice.json", "voice.json"].contains($0.path) && $0.size <= 65536 }),
           let manifest = try? JSONDecoder().decode(VoiceImportManifest.self, from: Data(try await text(file, inspection: result).utf8)) {
            result.manifest = manifest
            if let license = manifest.license { result.license = license }
        }
        for file in result.files.filter({ $0.ext == "list" && $0.size <= 1024 * 1024 }).prefix(10) {
            if let text = try? await text(file, inspection: result) { result.hints.merge(VoiceImportRules.listHints(text, files: result.files)) { first, _ in first } }
        }
        return result
    }
    func referenceHint(path: String, inspection: VoiceImportInspection) async -> VoiceReferenceHint? {
        if let hint = inspection.hints[path] { return hint }
        let stem = String(path.dropLast(URL(fileURLWithPath: path).pathExtension.count + 1))
        if let sidecar = inspection.files.first(where: { [stem + ".lab", stem + ".txt"].contains($0.path) && $0.size <= 65536 }),
           let value = try? await text(sidecar, inspection: inspection) {
            return VoiceReferenceHint(transcript: value.trimmingCharacters(in: .whitespacesAndNewlines), language: inspection.language)
        }
        return nil
    }
    private func localFile(_ path: String, folder: URL) throws -> URL {
        guard VoiceImportRules.relativePath(path) else { throw LocalError("Unsafe voice file path.") }
        let source = folder.appendingPathComponent(path).resolvingSymlinksInPath()
        guard source.path.hasPrefix(folder.path + "/"), (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw LocalError("A selected file is missing or points outside the voice folder.") }
        return source
    }
    func discard(_ id: String, support: URL) {
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: support.appendingPathComponent("voice-library").appendingPathComponent(id))
    }
    func install(_ selection: VoiceImportSelection, inspection: VoiceImportInspection, support: URL,
                 progress: @escaping @Sendable (String) -> Void) async throws -> VoiceProfile {
        guard !selection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, selection.name.count <= 160 else { throw LocalError("Enter a voice name.") }
        guard VoiceImportRules.versions.contains(selection.modelVersion), ["en", "zh", "ja"].contains(selection.language) else { throw LocalError("Choose a supported model version and reference language.") }
        guard !selection.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, selection.transcript.count <= 4000 else { throw LocalError("Enter the exact words spoken in the reference clip (up to 4,000 characters).") }
        guard selection.gpt.isEmpty == selection.sovits.isEmpty else { throw LocalError("Choose both checkpoints, or use the pretrained model without either checkpoint.") }
        if VoiceImportRules.version(in: [selection.sovits]) == "unsupported" || (VoiceImportRules.version(in: [selection.sovits]) == nil && VoiceImportRules.version(in: [selection.gpt]) == "unsupported") { throw LocalError("This checkpoint folder is marked v1, v3, or v4. Supported architectures are v2, v2Pro, and v2ProPlus.") }
        let id = UUID().uuidString
        let library = support.appendingPathComponent("voice-library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let stage = library.appendingPathComponent(".import-" + id), final = library.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: stage) } }
        var paths: [String: String] = [:]
        let requested = [("gpt", selection.gpt), ("sovits", selection.sovits), ("reference", selection.localReference == nil ? selection.reference : "")].filter { !$0.1.isEmpty }
        for (index, pair) in requested.enumerated() {
            try Task.checkCancellation()
            guard let file = inspection.files.first(where: { $0.path == pair.1 }), file.size > 0, file.size <= (pair.0 == "reference" ? 100 * 1024 * 1024 : 2 * 1024 * 1024 * 1024),
                  (pair.0 != "gpt" || file.ext == "ckpt"), (pair.0 != "sovits" || file.ext == "pth"), (pair.0 != "reference" || file.isAudio) else { throw LocalError("Choose an available voice file within the supported size limits.") }
            let name = pair.0 + "." + file.ext
            let destination = stage.appendingPathComponent(name)
            progress("File \(index + 1) of \(requested.count) · \(pair.1) (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))")
            if let folder = inspection.folder { try FileManager.default.copyItem(at: localFile(file.path, folder: folder), to: destination) }
            else {
                guard file.sha256 != nil || file.gitSHA1 != nil else { throw LocalError("The Hub did not supply a file hash. Download it separately and import a local folder.") }
                var request = URLRequest(url: try url(inspection.repository!, revision: inspection.revision!, path: file.path)); request.timeoutInterval = 120
                let (temporary, response) = try await session.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else { throw LocalError("Download failed. Check your connection and the repository's access settings.") }
                try FileManager.default.copyItem(at: temporary, to: destination)
            }
            try Task.checkCancellation()
            try VoiceImportRules.verify(destination, file: file)
            if pair.0 == "sovits", let detected = try VoiceImportRules.sovitsVersion(destination) {
                guard detected != "unsupported" else { throw LocalError("This SoVITS file's architecture header is unsupported. Use a v2, v2Pro, or v2ProPlus model.") }
                guard detected == selection.modelVersion else { throw LocalError("The SoVITS file identifies itself as \(detected). Select that model version and retry.") }
            }
            paths[pair.0] = name
        }
        if let reference = selection.localReference {
            let properties = try reference.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard properties.isRegularFile == true, (properties.fileSize ?? 0) <= 100 * 1024 * 1024 else { throw LocalError("Choose a reference audio file smaller than 100 MB.") }
            let name = "reference." + reference.pathExtension.lowercased()
            let destination = stage.appendingPathComponent(name)
            try FileManager.default.copyItem(at: reference.resolvingSymlinksInPath(), to: destination)
            guard (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw LocalError("Reference import produced a link. Choose the audio file itself.") }
            paths["reference"] = name
        }
        guard let reference = paths["reference"] else { throw LocalError("Choose a reference audio clip or provide your own.") }
        let audio = try AVAudioFile(forReading: stage.appendingPathComponent(reference))
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        guard seconds >= 3 && seconds <= 10 else { throw LocalError("The reference clip is \(String(format: "%.1f", seconds)) seconds. Choose a 3–10 second clip and its exact transcript.") }
        try Task.checkCancellation()
        let provenance: [String: String] = ["source": inspection.sourceURL?.absoluteString ?? inspection.folder?.lastPathComponent ?? "Folder", "revision": inspection.revision ?? "local", "gpt": selection.gpt, "sovits": selection.sovits, "reference": selection.localReference?.lastPathComponent ?? selection.reference]
        try saveJSON(provenance, to: stage.appendingPathComponent("provenance.json"))
        try Data(inspection.card.utf8).write(to: stage.appendingPathComponent("MODEL_CARD.md"))
        let reusable = VoiceImportManifest(name: selection.name, modelVersion: selection.modelVersion, language: selection.language,
            transcript: selection.transcript, reference: reference, gpt: paths["gpt"], sovits: paths["sovits"], license: inspection.license)
        try saveJSON(reusable, to: stage.appendingPathComponent("local-tts-mic.voice.json"))
        try FileManager.default.moveItem(at: stage, to: final); committed = true
        return VoiceProfile(id: id, name: selection.name, referencePath: final.appendingPathComponent(reference).path,
            transcript: selection.transcript, language: selection.language, modelVersion: selection.modelVersion,
            source: inspection.sourceURL?.absoluteString ?? "Imported folder: \(inspection.folder?.lastPathComponent ?? "Voice")", license: inspection.license,
            gptPath: paths["gpt"].map { final.appendingPathComponent($0).path }, sovitsPath: paths["sovits"].map { final.appendingPathComponent($0).path })
    }
}
