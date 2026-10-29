import XCTest
import AVFoundation
import CryptoKit
@testable import LocalSpeak

final class VoiceImportTests: XCTestCase {
    func testRepositoryParsingRejectsOtherHostsAndPinsTreeRevision() throws {
        XCTAssertEqual(try VoiceImportRules.repository("creator/voice").id, "creator/voice")
        let parsed = try VoiceImportRules.repository("https://huggingface.co/creator/voice/tree/abcdef")
        XCTAssertEqual(parsed.revision, "abcdef")
        for invalid in ["http://huggingface.co/a/b", "https://huggingface.co.evil.test/a/b", "https://user:secret@huggingface.co/a/b", "https://huggingface.co/datasets/a/b", "https://huggingface.co/models?search=voice", "../../private"] {
            XCTAssertThrowsError(try VoiceImportRules.repository(invalid), invalid)
        }
    }
    func testSafePathsAndModelArchitectureIgnoreCreatorReleaseNumbers() {
        for path in ["../model.pth", "/model.pth", "folder/../../model.pth", "a//b", "a/./b", "a\\b", ""] { XCTAssertFalse(VoiceImportRules.relativePath(path), path) }
        XCTAssertTrue(VoiceImportRules.relativePath("日本語/reference.wav"))
        XCTAssertEqual(VoiceImportRules.version(in: ["models/v2ProPlus/gotoh-v1-3.ckpt"]), "v2ProPlus")
        XCTAssertEqual(VoiceImportRules.version(in: ["SoVITS_weights_v2/model.pth"]), "v2")
        XCTAssertEqual(VoiceImportRules.version(in: ["models/v4/model.pth"]), "unsupported")
        XCTAssertNil(VoiceImportRules.version(in: ["model-v1-3.ckpt"]))
    }
    func testListTranscriptWindowsPathsAndAmbiguousBasenames() {
        let files = [VoiceImportFile(path: "audio/ref.wav", size: 10)]
        let hints = VoiceImportRules.listHints("C:\\voices\\ref.wav|speaker|JA|こんにちは。\ninvalid", files: files)
        XCTAssertEqual(hints["audio/ref.wav"]?.transcript, "こんにちは。")
        XCTAssertEqual(hints["audio/ref.wav"]?.language, "ja")
        XCTAssertTrue(VoiceImportRules.listHints("ref.wav|x|EN|Hello", files: files + [VoiceImportFile(path: "other/ref.wav", size: 1)]).isEmpty)
    }
    private func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func writeAudio(_ url: URL, seconds: Double = 4) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 32000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 32000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.1 }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
    func testHashMismatchAndGitBlobHashesAreVerified() throws {
        let file = try temporary().appendingPathComponent("file")
        try Data("voice".utf8).write(to: file)
        let sha = SHA256.hash(data: Data("voice".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try VoiceImportRules.verify(file, file: VoiceImportFile(path: "file", size: 5, sha256: sha)))
        XCTAssertThrowsError(try VoiceImportRules.verify(file, file: VoiceImportFile(path: "file", size: 5, sha256: "wrong")))
        XCTAssertThrowsError(try VoiceImportRules.verify(file, file: VoiceImportFile(path: "file", size: 6, sha256: sha)))
        let git = Insecure.SHA1.hash(data: Data("blob 5\0voice".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try VoiceImportRules.verify(file, file: VoiceImportFile(path: "file", size: 5, gitSHA1: git)))
        let link = file.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try VoiceImportRules.verify(link, file: VoiceImportFile(path: "link", size: 5)))
    }
    func testLocalFolderImportCopiesCheckpointsAndFindsSidecarWithoutExecutingThem() async throws {
        let root = try temporary(), folder = root.appendingPathComponent("download"), support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try writeAudio(folder.appendingPathComponent("ref.wav"))
        try Data("Not executable: arbitrary checkpoint bytes".utf8).write(to: folder.appendingPathComponent("voice.ckpt"))
        try Data("Not executable: arbitrary checkpoint bytes".utf8).write(to: folder.appendingPathComponent("voice.pth"))
        try Data("Hello there.".utf8).write(to: folder.appendingPathComponent("ref.lab"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("outside.wav"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let service = VoiceImportService()
        let inspection = try await service.inspect(folder: folder)
        XCTAssertEqual(Set(inspection.files.map(\.path)), Set(["ref.wav", "voice.ckpt", "voice.pth", "ref.lab"]), "Folder: \(folder.path)")
        XCTAssertFalse(inspection.files.contains { $0.path == "outside.wav" })
        let hint = await service.referenceHint(path: "ref.wav", inspection: inspection)
        XCTAssertEqual(hint?.transcript, "Hello there.")
        let selected = VoiceImportSelection(name: "Test", modelVersion: "v2", language: "en", transcript: "Hello there.", gpt: "voice.ckpt", sovits: "voice.pth", reference: "ref.wav")
        let voice = try await service.install(selected, inspection: inspection, support: support) { _ in }
        try FileManager.default.removeItem(at: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: voice.gptPath!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: voice.sovitsPath!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: voice.referencePath))
        XCTAssertTrue(voice.gptPath!.hasPrefix(support.path))
        let managed = URL(fileURLWithPath: voice.gptPath!).deletingLastPathComponent()
        let reusable = try await service.inspect(folder: managed)
        XCTAssertEqual(reusable.manifest?.transcript, "Hello there.")
        XCTAssertEqual(reusable.manifest?.gpt, "gpt.ckpt")
    }
    func testInvalidPairAndShortReferenceNeverCommitAVoice() async throws {
        let folder = try temporary(), support = folder.appendingPathComponent("support")
        try writeAudio(folder.appendingPathComponent("short.wav"), seconds: 1)
        let service = VoiceImportService(), inspection = try await service.inspect(folder: folder)
        let selected = VoiceImportSelection(name: "Test", modelVersion: "v2ProPlus", language: "en", transcript: "Hello", gpt: "", sovits: "", reference: "short.wav")
        do { _ = try await service.install(selected, inspection: inspection, support: support) { _ in }; XCTFail("Short reference accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("3–10")) }
        let remaining = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("voice-library"), includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty)
        var incomplete = selected; incomplete.gpt = "missing.ckpt"
        do { _ = try await service.install(incomplete, inspection: inspection, support: support) { _ in }; XCTFail("Unpaired checkpoint accepted") } catch { }
    }
    func testCuratedProfilesAreCompletePinnedAndInSupportedArchitectureFolders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try JSONDecoder().decode([VoiceCatalogueEntry].self, from: Data(contentsOf: root.appendingPathComponent("resources/voice-catalogue.json")))
        XCTAssertGreaterThanOrEqual(entries.count, 3)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        for entry in entries {
            XCTAssertEqual(entry.revision.count, 40)
            XCTAssertEqual(VoiceImportRules.version(in: [entry.gpt, entry.sovits]), entry.modelVersion)
            XCTAssertEqual(Set(entry.files.map(\.path)), Set([entry.gpt, entry.sovits, entry.reference]))
            XCTAssertTrue(entry.files.allSatisfy { $0.sha256?.count == 64 && $0.size > 0 })
            XCTAssertFalse(entry.transcript.isEmpty)
            XCTAssertTrue(entry.license.contains("Non-commercial"))
        }
    }
}

private final class HubMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let bytes = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

extension VoiceImportTests {
    func testHubInspectionPinsMetadataAndEncodesReferencePathsWithoutFetchingCheckpoints() async throws {
        let revision = String(repeating: "a", count: 40)
        let list = "こんにちは。"
        let metadata: [String: Any] = ["sha": revision, "cardData": ["license": "mit", "language": ["ja"]], "siblings": [
            ["rfilename": "model.ckpt", "size": 100, "blobId": String(repeating: "b", count: 40)],
            ["rfilename": "model.pth", "size": 100, "blobId": String(repeating: "b", count: 40)],
            ["rfilename": "音声#1.wav", "size": 100, "blobId": String(repeating: "b", count: 40)],
            ["rfilename": "音声#1.lab", "size": list.utf8.count, "blobId": String(repeating: "b", count: 40)]
        ]]
        let bytes = try JSONSerialization.data(withJSONObject: metadata)
        HubMockProtocol.handler = { request in
            let path = request.url!.path
            if path == "/api/models/owner/voice" { return bytes }
            XCTAssertEqual(path, "/owner/voice/resolve/\(revision)/音声#1.lab")
            XCTAssertTrue(request.url!.absoluteString.contains("%23"))
            return Data(list.utf8)
        }
        defer { HubMockProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HubMockProtocol.self]
        let service = VoiceImportService(session: URLSession(configuration: configuration))
        let inspection = try await service.inspect(repository: "owner/voice")
        XCTAssertEqual(inspection.revision, revision)
        XCTAssertEqual(inspection.language, "ja")
        let hint = await service.referenceHint(path: "音声#1.wav", inspection: inspection)
        XCTAssertEqual(hint?.transcript, "こんにちは。")
        XCTAssertEqual(inspection.sourceURL?.path, "/owner/voice/tree/\(revision)")
    }
}

extension VoiceImportTests {
    func testCanceledImportLeavesNoCommittedOrTemporaryVoice() async throws {
        let root = try temporary(), support = root.appendingPathComponent("support")
        try writeAudio(root.appendingPathComponent("ref.wav"))
        let service = VoiceImportService(), inspection = try await service.inspect(folder: root)
        let selected = VoiceImportSelection(name: "Canceled", modelVersion: "v2ProPlus", language: "en", transcript: "Hello", gpt: "", sovits: "", reference: "ref.wav")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.install(selected, inspection: inspection, support: support) { _ in }
        }
        do { _ = try await task.value; XCTFail("Canceled import completed") } catch { XCTAssertTrue(error is CancellationError) }
        let directory = support.appendingPathComponent("voice-library")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }
}

extension VoiceImportTests {
    func testSoVITSArchitectureHeadersCannotBeOverriddenByDirectoryNames() throws {
        let file = try temporary().appendingPathComponent("model.pth")
        try Data("04fake".utf8).write(to: file)
        XCTAssertEqual(try VoiceImportRules.sovitsVersion(file), "unsupported")
        try Data("06fake".utf8).write(to: file)
        XCTAssertEqual(try VoiceImportRules.sovitsVersion(file), "v2ProPlus")
        try Data("PKfake".utf8).write(to: file)
        XCTAssertNil(try VoiceImportRules.sovitsVersion(file))
    }
}
