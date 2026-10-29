import XCTest
import CoreAudio
@testable import LocalSpeak

final class SettingsTests: XCTestCase {
    func testStarterProfilesMatchWorkerContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("resources/starter-sources.json"))
        let sources = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let profiles = sources.map { VoiceProfile(id: $0["id"] as! String, name: $0["name"] as! String,
            referencePath: "/tmp/reference.wav", transcript: $0["transcript"] as! String,
            language: $0["language"] as! String, source: $0["source"] as? String, license: $0["license"] as? String) }
        XCTAssertEqual(Set(profiles.map(\.language)), Set(["en", "zh", "ja"]))
        XCTAssertEqual(sources.filter { ($0["optional"] as? Bool) != true }.count, 2)
        XCTAssertTrue(profiles.allSatisfy { !$0.transcript.isEmpty })
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles[1])) as! [String: Any]
        XCTAssertEqual(encoded["language"] as? String, "zh")
        XCTAssertNotNil(encoded["referencePath"])
        XCTAssertEqual(encoded["modelVersion"] as? String, "v2ProPlus")
    }

    func testDefaultRoutingIsExplicitAndPreviewIsOff() {
        let settings = Settings()
        XCTAssertFalse(settings.monitoring)
        XCTAssertEqual(settings.broadcastUID, AudioDevices.localMicUID)
        XCTAssertNotEqual(settings.overlayHotkey, settings.stopHotkey)
        XCTAssertEqual(settings.monitorUID, AudioDevices.followSystem)
    }

    func testExistingSettingsStillDecodeForPreviewMigration() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as! [String: Any]
        object.removeValue(forKey: "previewRoutingVersion")
        object["monitorUID"] = "BuiltInSpeakerDevice"
        object["broadcastUID"] = ""
        let old = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.previewRoutingVersion)
        XCTAssertEqual(old.monitorUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(old.broadcastUID, "")
    }

    func testPreviewFollowsSystemOutputExactly() {
        let cable = AudioDevice(id: 1, uid: "cable", name: "VB-Cable", inputs: 8, outputs: 8)
        let speakers = AudioDevice(id: 2, uid: "BuiltInSpeakerDevice", name: "Speakers", inputs: 0, outputs: 2)
        let headphones = AudioDevice(id: 3, uid: "headphones", name: "USB Headphones", inputs: 0, outputs: 2)
        XCTAssertEqual(AudioDevices.resolveMonitor(AudioDevices.followSystem, devices: [cable, headphones, speakers], systemOutput: 1)?.id, 1)
        XCTAssertEqual(AudioDevices.resolveMonitor(AudioDevices.followSystem, devices: [cable, headphones, speakers], systemOutput: 3)?.id, 3)
        XCTAssertEqual(AudioDevices.resolveMonitor("cable", devices: [cable, speakers])?.id, 1)
        XCTAssertNil(AudioDevices.resolveMonitor(AudioDevices.followSystem, devices: [speakers], systemOutput: 3))
    }
}

