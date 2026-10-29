import AVFoundation
import CoreAudio
import AudioToolbox

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int
}

enum AudioDevices {
    static let localMicUID = "local.localspeak.mic.device.v1"
    static let followSystem = "__system_output__"
    static func defaultOutputID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &result) == noErr else { return 0 }
        return result
    }
    static func resolveMonitor(_ uid: String, devices: [AudioDevice], systemOutput: AudioDeviceID? = nil) -> AudioDevice? {
        let current = systemOutput ?? defaultOutputID()
        return uid == followSystem ? devices.first { $0.id == current && $0.outputs > 0 } : devices.first { $0.uid == uid && $0.outputs > 0 }
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr else { return "" }
        return result?.takeUnretainedValue() as String? ?? ""
    }

    static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                        inputs: channels(id, kAudioDevicePropertyScopeInput), outputs: channels(id, kAudioDevicePropertyScopeOutput))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor protocol AudioRouting: AnyObject {
    func play(path: String, delivery: Delivery, settings: Settings, devices: [AudioDevice], completion: @escaping (Result<Void, Error>) -> Void) throws
    func stop()
    func finishMessage()
    func setVolume(_ volume: Float)
    func testTone(settings: Settings, devices: [AudioDevice]) throws
}

@MainActor final class AudioRouter: AudioRouting {
    private let renderer = AudioQueueRenderer()
    private let microphone = NativeMicRenderer()
    private var generation = UUID()

    func play(path: String, delivery: Delivery, settings: Settings, devices: [AudioDevice], completion: @escaping (Result<Void, Error>) -> Void) throws {
        let monitor = AudioDevices.resolveMonitor(settings.monitorUID, devices: devices)
        var outputs = Set<String>()
        if delivery == .broadcast { outputs.insert(AudioDevices.localMicUID) }
        if settings.monitoring || delivery == .preview {
            guard let monitor, monitor.uid != AudioDevices.localMicUID, monitor.uid != settings.broadcastUID else {
                throw LocalError("Choose speakers or headphones for private preview.")
            }
            outputs.insert(monitor.uid)
        }
        let mic = devices.first { $0.uid == AudioDevices.localMicUID && $0.outputs > 0 }
        if delivery == .broadcast && mic == nil {
            throw LocalError("Local TTS Mic is unavailable. Install its driver and restart audio, then try again.")
        }
        let token = generation
        let fanout = PlaybackFanout(outputs: outputs, completion: completion)
        func settle(_ uid: String, _ result: Result<Void, Error>) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                fanout.settle(uid, result: result)
            }
        }
        if delivery == .broadcast, let mic {
            microphone.play(path: path, device: mic, volume: settings.volume) { settle(mic.uid, $0) }
        }
        if (settings.monitoring || delivery == .preview), let monitor {
            renderer.play(path: path, targets: [monitor], volume: settings.volume) { settle(monitor.uid, $0) }
        }
    }
    func finishMessage() {
        // The mic sends continuous silence between utterances. Physical preview
        // routes can close independently without interrupting the mic clock.
        renderer.stop()
    }
    func stop() { generation = UUID(); renderer.stop(); microphone.stop() }
    func setVolume(_ volume: Float) { renderer.setVolume(volume); microphone.setVolume(volume) }
    func simulateConfigurationChange() { stop() }

    func testTone(settings: Settings, devices: [AudioDevice]) throws {
        let url = Paths.session.appendingPathComponent("routing-test.wav")
        try FileManager.default.createDirectory(at: Paths.session, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        for i in 0..<24000 {
            let envelope = min(1, Double(i) / 480) * min(1, Double(24000 - i) / 480)
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.15 * envelope)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        try play(path: url.path, delivery: .broadcast, settings: settings, devices: devices, completion: { _ in })
    }
}
