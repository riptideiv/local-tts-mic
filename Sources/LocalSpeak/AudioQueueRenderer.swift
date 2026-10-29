import AVFoundation
import AudioToolbox
import CoreAudio

// Every device/decoder call runs here, never on the AppKit thread. AudioQueue
// callbacks use a separate queue so synchronous disposal cannot deadlock them.
final class AudioQueueRenderer {
    private let work = DispatchQueue(label: "local.speak.audio.control", qos: .userInitiated)
    private let callbacks = DispatchQueue(label: "local.speak.audio.callbacks", qos: .userInitiated)
    private var routes: [String: QueueOutput] = [:]

    func play(path: String, targets: [AudioDevice], volume: Float, completion: @escaping (Result<Void, Error>) -> Void) {
        work.async { [self] in
            do {
                let pcm = try Self.decode(path)
                let group = PlaybackFanout(outputs: Set(targets.map(\.uid)), completion: completion)
                for device in targets {
                    do {
                        if let old = routes[device.uid], old.deviceID != device.id { old.close(); routes.removeValue(forKey: device.uid) }
                        if routes[device.uid] == nil {
                            routes[device.uid] = try QueueOutput(device: device, work: work, callbacks: callbacks)
                        }
                        try routes[device.uid]!.enqueue(pcm, volume: volume) { group.settle(device.uid, result: $0) }
                    } catch { group.settle(device.uid, result: .failure(error)) }
                }
            } catch { completion(.failure(error)) }
        }
    }

    func stop() { work.async { [self] in routes.values.forEach { $0.close() }; routes.removeAll() } }
    func setVolume(_ volume: Float) { work.async { [self] in routes.values.forEach { $0.setVolume(volume) } } }

    static func decode(_ path: String) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.length > 0, file.length < Int64(UInt32.max),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: stereo) else { throw LocalError("Cannot decode generated speech.") }
        try file.read(into: source)
        converter.channelMap = source.format.channelCount == 1 ? [0, 0] : [0, 1]
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * 48000 / source.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: capacity) else { throw LocalError("Cannot allocate speech playback buffer.") }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        guard status != .error, output.frameLength > 0 else { throw conversionError ?? LocalError("Speech resampling produced no audio.") as NSError }
        return output
    }
}

// Used on one serial control queue. Each output can settle once, even if the
// device reports a late callback after an error/reset.
final class PlaybackFanout {
    private var remaining: Set<String>
    private var finished = false
    private let completion: (Result<Void, Error>) -> Void
    init(outputs: Set<String>, completion: @escaping (Result<Void, Error>) -> Void) {
        remaining = outputs; self.completion = completion
    }
    func settle(_ output: String, result: Result<Void, Error>) {
        guard !finished, remaining.remove(output) != nil else { return }
        if case .failure = result { finished = true; completion(result) }
        else if remaining.isEmpty { finished = true; completion(.success(())) }
    }
}

private final class QueueOutput {
    let deviceID: AudioDeviceID
    private let uid: String
    private let work: DispatchQueue
    private var queue: AudioQueueRef?
    private var buffers: [UInt: UUID] = [:]
    private var completions: [UUID: (Result<Void, Error>) -> Void] = [:]
    private var scheduledAt: [UUID: TimeInterval] = [:]
    private var expectedEnd = 0.0
    private var closed = false
    private let tail: Double

    init(device: AudioDevice, work: DispatchQueue, callbacks: DispatchQueue) throws {
        deviceID = device.id; uid = device.uid; self.work = work
        tail = Self.outputLatency(device.id) + 0.05
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let status = AudioQueueNewOutputWithDispatchQueue(&queue, &format, 0, callbacks) { [weak self] aq, buffer in
            // Only carry addresses across queues. Disposal may invalidate them.
            let address = UInt(bitPattern: buffer)
            self?.work.async { [weak self] in self?.consumed(aq, address: address) }
        }
        guard status == noErr, let queue else { throw LocalError("Cannot open \(device.name) (AudioQueue \(status)).") }
        let cfUID = uid as CFString
        var pointer = Unmanaged.passUnretained(cfUID).toOpaque()
        let bound = withExtendedLifetime(cfUID) { AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &pointer, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)) }
        guard bound == noErr else { AudioQueueDispose(queue, true); self.queue = nil; throw LocalError("Cannot select \(device.name) (AudioQueue \(bound)).") }
        Diagnostics.audio("queue opened device=\(device.name):\(device.id) uid=\(uid) tail=\(tail)")
    }

    func enqueue(_ pcm: AVAudioPCMBuffer, volume: Float, done: @escaping (Result<Void, Error>) -> Void) throws {
        guard !closed, let queue else { throw LocalError("The audio output is closed.") }
        let bytes = pcm.audioBufferList.pointee.mBuffers.mDataByteSize
        var buffer: AudioQueueBufferRef?
        let allocated = AudioQueueAllocateBuffer(queue, bytes, &buffer)
        guard allocated == noErr, let buffer, let data = pcm.audioBufferList.pointee.mBuffers.mData else { throw LocalError("Cannot allocate an audio queue buffer (\(allocated)).") }
        memcpy(buffer.pointee.mAudioData, data, Int(bytes)); buffer.pointee.mAudioDataByteSize = bytes
        let ticket = UUID()
        let address = UInt(bitPattern: buffer)
        buffers[address] = ticket; completions[ticket] = done
        scheduledAt[ticket] = ProcessInfo.processInfo.systemUptime
        setVolume(volume)
        let enqueued = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        guard enqueued == noErr else {
            buffers.removeValue(forKey: address); completions.removeValue(forKey: ticket)
            AudioQueueFreeBuffer(queue, buffer); throw LocalError("Cannot queue speech (\(enqueued)).")
        }
        let duration = Double(pcm.frameLength) / 48000
        expectedEnd = max(ProcessInfo.processInfo.systemUptime, expectedEnd) + duration
        let earliestEnd = expectedEnd
        // Keep the completion's wall-clock lower bound; a reset callback must
        // never be mistaken for an instantly delivered sentence.
        endTimes[ticket] = earliestEnd
        let started = AudioQueueStart(queue, nil)
        guard started == noErr else { close(); throw LocalError("Cannot start speech output (\(started)).") }
        Diagnostics.audio("queue scheduled ticket=\(ticket) uid=\(uid) seconds=\(duration)")
    }

    private var endTimes: [UUID: TimeInterval] = [:]
    private func consumed(_ source: AudioQueueRef, address: UInt) {
        guard !closed, source == queue, let ticket = buffers.removeValue(forKey: address),
              let buffer = AudioQueueBufferRef(bitPattern: address) else { return }
        AudioQueueFreeBuffer(source, buffer)
        var running: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        AudioQueueGetProperty(source, kAudioQueueProperty_IsRunning, &running, &size)
        Diagnostics.audio("queue consumed ticket=\(ticket) uid=\(uid) after=\(ProcessInfo.processInfo.systemUptime - (scheduledAt.removeValue(forKey: ticket) ?? 0)) running=\(running)")
        let delay = max(tail, (endTimes[ticket] ?? 0) - ProcessInfo.processInfo.systemUptime + tail)
        work.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed, let completion = self.completions.removeValue(forKey: ticket) else { return }
            self.endTimes.removeValue(forKey: ticket)
            Diagnostics.audio("queue completed ticket=\(ticket) uid=\(self.uid)")
            completion(.success(()))
        }
    }

    func setVolume(_ volume: Float) { if let queue { AudioQueueSetParameter(queue, kAudioQueueParam_Volume, volume) } }
    func close() {
        guard !closed else { return }
        closed = true
        let pending = Array(completions.values)
        completions.removeAll(); buffers.removeAll(); endTimes.removeAll(); scheduledAt.removeAll()
        if let queue { AudioQueueStop(queue, true); AudioQueueDispose(queue, true) }
        queue = nil
        for completion in pending { completion(.failure(LocalError("Playback was stopped."))) }
    }

    private static func outputLatency(_ id: AudioDeviceID) -> Double {
        func frames(_ selector: AudioObjectPropertySelector) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
            return value
        }
        return Double(frames(kAudioDevicePropertyLatency) + frames(kAudioDevicePropertySafetyOffset) + frames(kAudioDevicePropertyBufferFrameSize)) / 48000
    }
}
