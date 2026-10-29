import AVFoundation
import CoreAudio
import CMicTransport

final class NativeMicRenderer {
    private let work = DispatchQueue(label: "local.speak.mic.control", qos: .userInitiated)
    private var output: NativeMicOutput?

    func play(path: String, device: AudioDevice, volume: Float, completion: @escaping (Result<Void, Error>) -> Void) {
        work.async { [self] in
            do {
                let pcm = try AudioQueueRenderer.decode(path)
                if output?.deviceID != device.id { output?.close(); output = nil }
                if output == nil { output = try NativeMicOutput(device: device, work: work) }
                try output!.enqueue(pcm, volume: volume, completion: completion)
            } catch { completion(.failure(error)) }
        }
    }
    func setVolume(_ value: Float) { work.async { [self] in output?.setVolume(value) } }
    func stop() { work.async { [self] in output?.close(); output = nil } }
}

private final class NativeMicOutput {
    let deviceID: AudioDeviceID
    private var ioProc: AudioDeviceIOProcID?
    private var transport: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var completions: [UInt64: (Result<Void, Error>) -> Void] = [:]
    private let work: DispatchQueue
    private var started = false
    private var closed = false
    private let tail = 0.10

    init(device: AudioDevice, work: DispatchQueue) throws {
        deviceID = device.id; self.work = work
        guard device.uid == AudioDevices.localMicUID, device.outputs == 2 else {
            throw LocalError("The selected output is not Local TTS Mic.")
        }
        var stream = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &stream) == noErr, stream != 0 else {
            throw LocalError("Local TTS Mic has no output stream.")
        }
        var format = AudioStreamBasicDescription()
        address.mSelector = kAudioStreamPropertyVirtualFormat; address.mScope = kAudioObjectPropertyScopeGlobal
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate == 48000, format.mChannelsPerFrame == 2,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBytesPerFrame == 8, format.mBitsPerChannel == 32 else {
            throw LocalError("Local TTS Mic did not provide its expected 48 kHz audio format.")
        }
        guard let pcmQueue = LSMTransportCreate() else { throw LocalError("Cannot allocate microphone playback queue.") }
        transport = pcmQueue
        let created = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device.id, nil) { _, _, _, buffers, _ in
            // The callback only enters the C consumer. It emits zeros while idle
            // and never allocates, locks, logs or invokes a Swift completion.
            LSMTransportRender(pcmQueue, buffers)
        }
        guard created == noErr else {
            LSMTransportDestroy(pcmQueue); transport = nil
            throw LocalError("Cannot open Local TTS Mic (Core Audio \(created)).")
        }
        let poll = DispatchSource.makeTimerSource(queue: work)
        poll.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        poll.setEventHandler { [weak self] in self?.collect() }
        timer = poll; poll.resume()
        Diagnostics.audio("native microphone opened id=\(device.id)")
    }

    func enqueue(_ pcm: AVAudioPCMBuffer, volume: Float, completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard !closed, let transport, let pointer = pcm.audioBufferList.pointee.mBuffers.mData else { throw LocalError("Microphone output is closed.") }
        let ticket = LSMTransportAppend(transport, pointer.assumingMemoryBound(to: Float.self), pcm.frameLength)
        guard ticket != 0 else { throw LocalError("The microphone audio buffer is full.") }
        completions[ticket] = completion
        setVolume(volume)
        if !started {
            let status = AudioDeviceStart(deviceID, ioProc)
            guard status == noErr else { close(); throw LocalError("Cannot start Local TTS Mic (Core Audio \(status)).") }
            started = true
        }
        Diagnostics.audio("native microphone queued ticket=\(ticket) frames=\(pcm.frameLength)")
    }

    private func collect() {
        guard !closed, let transport else { return }
        let consumed = LSMTransportCompleted(transport)
        LSMTransportCollect(transport)
        // Keep callbacks pending through the driver and hardware buffer tail.
        for ticket in completions.keys.sorted() where ticket <= consumed && !finishing.contains(ticket) {
            finishing.insert(ticket)
            work.asyncAfter(deadline: .now() + tail) { [weak self] in
                guard let self, !self.closed, let done = self.completions.removeValue(forKey: ticket) else { return }
                self.finishing.remove(ticket)
                Diagnostics.audio("native microphone completed ticket=\(ticket)")
                done(.success(()))
            }
        }
    }
    private var finishing: Set<UInt64> = []

    func setVolume(_ value: Float) { if let transport { LSMTransportSetVolume(transport, value) } }
    func close() {
        guard !closed else { return }; closed = true
        timer?.cancel(); timer = nil
        if started { AudioDeviceStop(deviceID, ioProc) }
        if let ioProc { AudioDeviceDestroyIOProcID(deviceID, ioProc) }
        ioProc = nil
        if let transport { LSMTransportDestroy(transport) }; transport = nil
        let pending = Array(completions.values); completions.removeAll(); finishing.removeAll()
        for done in pending { done(.failure(LocalError("Microphone playback was stopped."))) }
    }
}
