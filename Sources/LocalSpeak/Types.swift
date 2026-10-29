import Foundation
import AppKit

enum Paths {
    static let root: URL = {
        if let value = ProcessInfo.processInfo.environment["LOCALSPEAK_ROOT"] ?? Bundle.main.object(forInfoDictionaryKey: "LocalSpeakRoot") as? String {
            return URL(fileURLWithPath: value)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()
    static let runtime = root.appendingPathComponent("runtime")
    static let support: URL = {
        if let path = ProcessInfo.processInfo.environment["LOCALSPEAK_SUPPORT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Local Speak")
    }()
    static let session = runtime.appendingPathComponent("sessions/\(UUID().uuidString)")
    static let settings = support.appendingPathComponent("settings.json")
    static let voices = support.appendingPathComponent("voices.json")
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

