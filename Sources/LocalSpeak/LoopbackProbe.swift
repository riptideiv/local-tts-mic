// Explicit diagnostic mode. Captures only Local TTS Mic, never the physical microphone.
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

final class CaptureStats: @unchecked Sendable {
    private let lock = NSLock()
    private var squares = [Double]()
    private var frames = 0
    private var baselineSquares = 0.0
    private var baselineFrames = 0
    private var signalStarted = false
    private var samples = [Float]()
    private let channels = 2
    private var secondSegment = false
    private var secondSquares = [Double](repeating: 0, count: 2)
    private var secondFrames = 0
    func startSignal() { lock.lock(); signalStarted = true; lock.unlock() }
    func startSecondSignal() { lock.lock(); secondSegment = true; lock.unlock() }
    func add(_ buffer: AudioQueueBufferRef) {
        lock.lock(); defer { lock.unlock() }
        if squares.isEmpty { squares = Array(repeating: 0, count: channels) }
        let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
        let frameCount = count / channels
        let data = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
        for channel in 0..<squares.count {
            var sum = 0.0
            for index in 0..<frameCount { let sample = Double(data[index * channels + channel]); sum += sample * sample }
            if signalStarted { squares[channel] += sum }
            else { baselineSquares += sum }
            if secondSegment { secondSquares[channel] += sum }
        }
        if signalStarted { frames += frameCount }
        else { baselineFrames += frameCount * squares.count }
        if secondSegment { secondFrames += frameCount }
    }
    func write(to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty,
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else {
            throw LocalError("The virtual input returned no samples or an unsupported format.")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / channels)) else {
            throw LocalError("Cannot allocate the virtual-input recording buffer.")
        }
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<channels {
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = samples[i * channels + c] }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    func report() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["frames": frames, "channelRMS": squares.map { sqrt($0 / Double(max(1, frames))) },
                "baselineRMS": sqrt(baselineSquares / Double(max(1, baselineFrames))),
                "secondChannelRMS": secondSquares.map { sqrt($0 / Double(max(1, secondFrames))) }]
    }
}

@MainActor enum LoopbackProbe {
    private static var recorder: AudioQueueRef?
    private static var captureStats: CaptureStats?
    private static var audio: AudioRouter?
    static func run(source: String, report: String, preview: Bool, reset: Bool = false, monitoring: Bool = false) {
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            DispatchQueue.main.async {
                guard allowed else {
                    finish(["error": "Microphone permission is needed to record the virtual cable."], report: report, code: 2)
                    return
                }
                do { try capture(source: source, report: report, preview: preview, reset: reset, monitoring: monitoring) }
                catch { finish(["error": error.localizedDescription], report: report, code: 1) }
            }
        }
    }
    private static func capture(source: String, report: String, preview: Bool, reset: Bool, monitoring: Bool) throws {
        let devices = AudioDevices.all()
        let recorded = URL(fileURLWithPath: report).deletingPathExtension().appendingPathExtension("wav")
        let stats = CaptureStats(); captureStats = stats
        let (queue, cable) = try startCapture(stats: stats)
        recorder = queue
        var settings = Settings()
        settings.broadcastUID = cable.uid
        settings.volume = 0.8
        settings.monitoring = monitoring
        settings.monitorUID = AudioDevices.followSystem
        let route = AudioRouter(); audio = route
        let sourceFile = try AVAudioFile(forReading: URL(fileURLWithPath: source))
        let duration = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate
        var completed = false
        func conclude(_ failure: Error? = nil) {
            guard !completed else { return }; completed = true
            route.stop(); AudioQueueStop(queue, true); AudioQueueDispose(queue, true)
            try? stats.write(to: recorded)
            var values = stats.report()
            values["preview"] = preview
            values["monitoring"] = monitoring
            values["resetBetweenMessages"] = reset
            values["monitor"] = AudioDevices.resolveMonitor(settings.monitorUID, devices: devices)?.name ?? "unavailable"
            values["input"] = cable.name
            values["sampleRate"] = 48000
            values["recording"] = recorded.path
            let levels = values["channelRMS"] as? [Double] ?? []
            let second = values["secondChannelRMS"] as? [Double] ?? []
            let valid = failure == nil && !levels.isEmpty && (preview ? levels.allSatisfy { $0 < 0.0001 } : levels.prefix(2).contains { $0 > 0.001 }) && (!reset || preview || second.prefix(2).contains { $0 > 0.001 })
            values["passed"] = valid
            if let failure { values["error"] = failure.localizedDescription }
            finish(values, report: report, code: valid ? 0 : 1)
        }
        func play(second: Bool) {
            if second { stats.startSecondSignal() } else { stats.startSignal() }
            do {
                try route.play(path: source, delivery: preview ? .preview : .broadcast, settings: settings, devices: devices) { result in
                    switch result {
                    case .failure(let error): conclude(error)
                    case .success:
                        if reset && !second {
                            route.simulateConfigurationChange()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { play(second: true) }
                        } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { conclude() } }
                    }
                }
            } catch { conclude(error) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { play(second: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * duration + 25) { conclude(LocalError("Playback completion timed out.")) }
    }
    static func startCapture(stats: CaptureStats) throws -> (AudioQueueRef, AudioDevice) {
        guard let cable = AudioDevices.all().first(where: { $0.uid == AudioDevices.localMicUID && $0.inputs > 0 && $0.outputs > 0 }) else {
            throw LocalError("Local TTS Mic is unavailable")
        }
        guard cable.inputs == 2 else { throw LocalError("This diagnostic expects the installed two-channel Local TTS Mic.") }
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var queue: AudioQueueRef?
        let created = AudioQueueNewInput(&format, { raw, queue, buffer, _, _, _ in
            guard let raw else { return }
            Unmanaged<CaptureStats>.fromOpaque(raw).takeUnretainedValue().add(buffer)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }, Unmanaged.passUnretained(stats).toOpaque(), nil, nil, 0, &queue)
        guard created == noErr, let queue else { throw LocalError("Cannot create virtual input queue: \(created)") }
        let uid = cable.uid as CFString
        var uidRef = Unmanaged.passUnretained(uid).toOpaque()
        let bound = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uidRef, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size))
        guard bound == noErr else { AudioQueueDispose(queue, true); throw LocalError("Cannot bind Local TTS Mic input: \(bound)") }
        var actual: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let checked = AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &actual, &propertySize)
        guard checked == noErr, (actual?.takeUnretainedValue() as String?) == cable.uid else {
            AudioQueueDispose(queue, true); throw LocalError("Capture device is not Local TTS Mic; no recording was made.")
        }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, 32768, &buffer)
            if let buffer { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
        }
        let status = AudioQueueStart(queue, nil)
        guard status == noErr else { AudioQueueDispose(queue, true); throw LocalError("Cannot start Local TTS Mic capture: \(status)") }
        return (queue, cable)
    }
    private static func finish(_ values: [String: Any], report: String, code: Int32) {
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: report), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        }
        exit(code)
    }
}
