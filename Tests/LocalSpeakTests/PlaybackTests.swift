import XCTest
@testable import LocalSpeak

final class PlaybackTests: XCTestCase {
    func testMissingAndDuplicateCallbacksCannotCompleteMessage() {
        var progress = PlaybackProgress()
        let a = UUID(), b = UUID()
        XCTAssertEqual(progress.add(a, seconds: 4, now: 10), 22)
        XCTAssertEqual(progress.add(b, seconds: 3, now: 11), 25)
        progress.generated()
        XCTAssertTrue(progress.settle(a))
        XCTAssertFalse(progress.settle(a))
        XCTAssertFalse(progress.isFinished)
        XCTAssertTrue(progress.pending.contains(b))
        XCTAssertTrue(progress.settle(b))
        XCTAssertTrue(progress.isFinished)
    }

    func testFanoutWaitsForBothOutputsAndSettlesFailureOnce() {
        var successes = 0, failures = 0
        let group = PlaybackFanout(outputs: ["cable", "headset"]) { result in
            switch result { case .success: successes += 1; case .failure: failures += 1 }
        }
        group.settle("cable", result: .success(()))
        XCTAssertEqual(successes, 0)
        group.settle("headset", result: .failure(LocalError("Disconnected")))
        group.settle("headset", result: .success(()))
        group.settle("cable", result: .success(()))
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(failures, 1)
    }

    @MainActor func testPlaybackFailurePreservesQueueAndIgnoresLateCallback() {
        let worker = FakeWorker(), audio = FakeAudio()
        let model = makeModel(worker, audio)
        XCTAssertTrue(model.submit(text: "First message", delivery: .preview))
        XCTAssertTrue(model.submit(text: "Second message", delivery: .preview))
        let first = model.jobs[0].id
        worker.emit("audio", first)
        worker.emit("complete", first)
        let late = audio.callbacks[0]
        late(.failure(LocalError("Device disconnected")))
        XCTAssertEqual(model.jobs.map(\.status), ["Failed", "Generating"])
        late(.success(()))
        XCTAssertEqual(model.jobs[1].status, "Generating")
        let second = model.jobs[1].id
        worker.emit("audio", second)
        audio.callbacks[1](.success(()))
        XCTAssertEqual(model.jobs[1].status, "Previewing")
        worker.emit("complete", second)
        XCTAssertEqual(model.jobs[1].status, "Done")
        XCTAssertFalse(model.busy)
    }

    @MainActor func testMissingCancellationAckRestartsWorkerAndKeepsBacklog() async throws {
        let worker = FakeWorker(), audio = FakeAudio()
        let model = makeModel(worker, audio, grace: 0.01)
        XCTAssertTrue(model.submit(text: "First", delivery: .preview))
        XCTAssertTrue(model.submit(text: "Second", delivery: .preview))
        worker.emit("audio", model.jobs[0].id)
        audio.callbacks[0](.failure(LocalError("Playback failed")))
        XCTAssertEqual(model.jobs.map(\.status), ["Failed", "Queued"])
        try await waitUntil("worker restart") { worker.starts == 1 }
        XCTAssertEqual(worker.starts, 1)
        XCTAssertFalse(model.ready)
        worker.emit("ready")
        XCTAssertEqual(model.jobs.map(\.status), ["Failed", "Generating"])
    }

    @MainActor func testMissingPlaybackCallbackTimesOutAndAdvancesQueue() async throws {
        let worker = FakeWorker(), audio = FakeAudio()
        let model = makeModel(worker, audio, playbackGrace: 0.01)
        XCTAssertTrue(model.submit(text: "First", delivery: .preview))
        XCTAssertTrue(model.submit(text: "Second", delivery: .preview))
        let first = model.jobs[0].id
        worker.emit("audio", first)
        worker.emit("complete", first)
        try await waitUntil("next queued message starts") { model.jobs[1].status == "Generating" }
        XCTAssertEqual(model.jobs.map(\.status), ["Failed", "Generating"])
        audio.callbacks[0](.success(()))
        XCTAssertEqual(model.jobs[1].status, "Generating")
    }

    @MainActor func testUnresponsiveSynthesisDoesNotLockQueue() async throws {
        let worker = FakeWorker(), audio = FakeAudio()
        let model = makeModel(worker, audio, grace: 0.01, synthesisGrace: 0.01)
        XCTAssertTrue(model.submit(text: "First", delivery: .preview))
        XCTAssertTrue(model.submit(text: "Second", delivery: .preview))
        try await waitUntil("worker restart") { worker.starts == 1 }
        XCTAssertEqual(model.jobs.map(\.status), ["Failed", "Queued"])
        XCTAssertEqual(worker.starts, 1)
        worker.emit("ready")
        XCTAssertEqual(model.jobs[1].status, "Generating")
    }

    @MainActor func testEnterUsesSendAndPreviewToggleWithoutClearingQueue() {
        let worker = FakeWorker(), audio = FakeAudio()
        let model = makeModel(worker, audio)
        model.devices = [AudioDevice(id: 9001, uid: AudioDevices.localMicUID, name: "Local TTS Mic", inputs: 2, outputs: 2)]
        model.settings.monitoring = true
        XCTAssertTrue(model.submit(text: "First message"))
        let first = model.jobs[0].id
        model.settings.monitoring = false
        XCTAssertTrue(model.submit(text: "Second message"))
        XCTAssertEqual(model.jobs.map(\.status), ["Generating", "Queued"])
        XCTAssertTrue(worker.cancelled.isEmpty)
        XCTAssertEqual(model.jobs.map(\.monitoring), [true, false])
        worker.emit("audio", first)
        XCTAssertEqual(audio.monitoringFlags, [true])
        worker.emit("complete", first)
        audio.callbacks[0](.success(()))
        worker.emit("audio", model.jobs[1].id)
        XCTAssertEqual(audio.monitoringFlags, [true, false])
        XCTAssertEqual(audio.deliveries, [.broadcast, .broadcast])
    }

    @MainActor func testPrivatePreviewRemainsPrivateWithSendPreviewEnabled() {
        let worker = FakeWorker(), audio = FakeAudio()
        let model = makeModel(worker, audio)
        model.settings.monitoring = true
        XCTAssertTrue(model.submit(text: "Only I should hear this", delivery: .preview))
        let id = model.jobs[0].id
        XCTAssertFalse(model.jobs[0].monitoring)
        worker.emit("audio", id)
        XCTAssertEqual(audio.deliveries, [.preview])
        XCTAssertEqual(audio.monitoringFlags, [false])
    }

    @MainActor func testVoicePreviewKeepsTheChosenBroadcastVoice() {
        let worker = FakeWorker(), audio = FakeAudio()
        let model = makeModel(worker, audio)
        let previous = model.settings
        let voice = VoiceProfile(id: "other", name: "Other", referencePath: "/tmp/other.wav", transcript: "Reference", language: "ja")
        model.voices.append(voice)
        model.previewVoice(voice)
        XCTAssertEqual(model.settings.selectedVoice, previous.selectedVoice)
        XCTAssertEqual(model.settings.language, previous.language)
        XCTAssertEqual(model.jobs.last?.voice.id, "other")
        XCTAssertEqual(model.jobs.last?.language, "ja")
        XCTAssertEqual(model.jobs.last?.delivery, .preview)
    }

    @MainActor private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for \(description)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func makeModel(_ worker: FakeWorker, _ audio: FakeAudio, grace: Double = 3, playbackGrace: Double = 8, synthesisGrace: Double = 90) -> AppModel {
        let model = AppModel(worker: worker, audio: audio, startAutomatically: false, cancellationGrace: grace, playbackGrace: playbackGrace, synthesisGrace: synthesisGrace, persistChanges: false)
        // Queue/routing tests use a fake worker and need no installed voices,
        // reference files, models, or the user's Application Support data.
        model.voices = [VoiceProfile(id: "test-voice", name: "Test voice", referencePath: "/tmp/reference.wav", transcript: "Test reference.", language: "en")]
        model.settings.selectedVoice = "test-voice"
        worker.emit("ready")
        return model
    }
}

@MainActor private final class FakeWorker: SpeechWorking {
    var onEvent: (([String: Any]) -> Void)?
    var starts = 0
    var cancelled: [String] = []
    func start(device: String) throws { starts += 1 }
    func synthesize(_ job: SpeechJob) throws {}
    func cancel(_ id: String) { cancelled.append(id) }
    func stop() {}
    func emit(_ type: String, _ id: String = "") { onEvent?(["type": type, "id": id, "path": "/tmp/speech.wav", "seconds": 0.1]) }
}

@MainActor private final class FakeAudio: AudioRouting {
    var callbacks: [(Result<Void, Error>) -> Void] = []
    var monitoringFlags: [Bool] = []
    var deliveries: [Delivery] = []
    func play(path: String, delivery: Delivery, settings: Settings, devices: [AudioDevice], completion: @escaping (Result<Void, Error>) -> Void) throws {
        callbacks.append(completion); monitoringFlags.append(settings.monitoring); deliveries.append(delivery)
    }
    func stop() {}
    func finishMessage() {}
    func setVolume(_ volume: Float) {}
    func testTone(settings: Settings, devices: [AudioDevice]) throws {}
}
