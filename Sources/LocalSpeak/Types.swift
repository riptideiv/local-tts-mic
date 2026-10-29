import Foundation
import AppKit

enum Paths {
    static let packaged = Bundle.main.object(forInfoDictionaryKey: "LocalSpeakPackaged") as? Bool == true
    static let support: URL = {
        if let path = ProcessInfo.processInfo.environment["LOCALSPEAK_SUPPORT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Local Speak")
    }()
    static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["LOCALSPEAK_ROOT"] { return URL(fileURLWithPath: path) }
        if packaged { return support.appendingPathComponent("Managed") }
        if let path = Bundle.main.object(forInfoDictionaryKey: "LocalSpeakRoot") as? String { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()
    // Packaged code is read-only; downloaded models and generated files are per-user.
    static let source = packaged ? Bundle.main.resourceURL!.appendingPathComponent("LocalTTSMic") : root
    static let runtime = root.appendingPathComponent("runtime")
    static let python = packaged ? source.appendingPathComponent("python/bin/python3") : runtime.appendingPathComponent(".venv/bin/python")
    static var searchPath: String {
        let bundled = runtime.appendingPathComponent("bin").path + ":" + python.deletingLastPathComponent().path
        return bundled + (packaged ? ":/usr/bin:/bin:/usr/sbin:/sbin" : ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }
    static let session = runtime.appendingPathComponent("sessions/\(UUID().uuidString)")
    static let settings = support.appendingPathComponent("settings.json")
    static let voices = support.appendingPathComponent("voices.json")
    static var runtimeReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        if !packaged { return true }
        guard let expected = loadJSON([String: String].self, from: source.appendingPathComponent("runtime-manifest.json")),
              let installed = loadJSON([String: String].self, from: runtime.appendingPathComponent("setup-complete.json")),
              expected["runtimeID"] == installed["runtimeID"] else { return false }
        return FileManager.default.fileExists(atPath: runtime.appendingPathComponent("starter-voices.json").path)
    }
}

struct VoiceProfile: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var referencePath: String
    var transcript: String
    var language: String
    var modelVersion = "v2ProPlus"
    var speed = 1.0
    var source: String?
    var license: String?
    var gptPath: String?
    var sovitsPath: String?
    var catalogueID: String?

    var languageName: String { languageLabel(language) }
    var isStarter: Bool { id.hasPrefix("starter-") }
}

func languageLabel(_ code: String) -> String {
    ["auto": "Auto", "en": "English", "zh": "中文 · Mandarin", "ja": "日本語 · Japanese"][code] ?? code
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32 = 49
    var modifiers: UInt32 = 6144 // controlKey | optionKey
    var label = "⌃⌥Space"
}

struct Settings: Codable {
    var selectedVoice = "starter-en"
    var language = "en"
    var speed = 1.0
    var broadcastUID = AudioDevices.localMicUID
    var monitorUID = AudioDevices.followSystem
    var previewRoutingVersion: Int? = 1
    var monitoring = false
    var volume: Float = 0.8
    var device = "cpu"
    var phrases = ["Hello! Give me a moment to type.", "Thanks, that sounds good.", "你好，稍等一下，我正在打字。", "こんにちは。少し待ってください。"]
    var overlayHotkey = Hotkey()
    var stopHotkey = Hotkey(keyCode: 53, modifiers: 6144, label: "⌃⌥Esc")
}

enum Delivery: String { case broadcast = "Speak", preview = "Preview" }

struct SpeechJob: Identifiable {
    let id = UUID().uuidString
    let text: String
    let voice: VoiceProfile
    let language: String
    let speed: Double
    let delivery: Delivery
    var monitoring = false
    var status = "Queued"
    var output: String?
    var firstAudio: Double?
    var seconds: Double?
    var elapsed: Double?
}

struct LocalError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

