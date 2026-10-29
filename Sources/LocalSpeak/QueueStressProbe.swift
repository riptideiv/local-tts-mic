import AppKit
import AVFoundation
import AudioToolbox

// Explicit diagnostic: exercise the same AppModel, worker and output used by UI.
@MainActor enum QueueStressProbe {
    private static var model: AppModel?
    private static var timer: Timer?
    private static var recorder: AudioQueueRef?
    static func run(report: String) {
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            DispatchQueue.main.async {
                guard allowed else { print("Virtual cable capture needs microphone permission."); exit(2) }
                do { try start(report: report) } catch { print(error); exit(1) }
            }
        }
    }
    private static func start(report: String) throws {
        let stats = CaptureStats()
        let (queue, _) = try LoopbackProbe.startCapture(stats: stats)
        recorder = queue
        stats.startSignal()
        let recorded = URL(fileURLWithPath: report).deletingPathExtension().appendingPathExtension("wav")
        let instance = AppModel(persistChanges: false)
        instance.settings.selectedVoice = "starter-en"
        instance.settings.language = "en"
        instance.settings.monitoring = false
        instance.settings.volume = 0.8
        model = instance
        let start = ProcessInfo.processInfo.systemUptime
        var lastTick = start, maxStall = 0.0
        var phase = 0, idleSince: Double?, finalSince: Double?
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                maxStall = max(maxStall, now - lastTick); lastTick = now
                if instance.ready, phase == 0 {
                    phase = 1
                    for number in 1...6 { instance.submit(text: "Queue check number \(number). This sentence should finish completely.") }
                }
                if phase == 1, instance.jobs.count == 6, !instance.busy, instance.queueCount == 0 {
                    if idleSince == nil { idleSince = now }
                    if now - idleSince! > 2 {
                        phase = 2
                        for number in 7...9 { instance.submit(text: "Queue check number \(number). Playback resumes after being idle.") }
                    }
                }
                let failed = instance.jobs.contains { $0.status == "Failed" }
                let done = phase == 2 && instance.jobs.count == 9 && !instance.busy && instance.queueCount == 0
                if done && finalSince == nil { finalSince = now }
                // Let the input queue deliver its last partially filled buffers.
                if (done && now - (finalSince ?? now) > 0.5) || failed || now - start > 180 {
                    let passed = done && instance.jobs.allSatisfy { $0.status == "Done" }
                    var values: [String: Any] = ["passed": passed, "maxMainThreadTickSeconds": maxStall,
                        "elapsed": now - start, "error": instance.error ?? "",
                        "jobs": instance.jobs.map { ["id": $0.id, "status": $0.status, "seconds": $0.seconds ?? 0, "output": $0.output ?? ""] as [String: Any] }]
                    timer?.invalidate(); instance.shutdown()
                    if let recorder { AudioQueueStop(recorder, true); AudioQueueDispose(recorder, true) }
                    recorder = nil
                    do { try stats.write(to: recorded) } catch { values["captureError"] = error.localizedDescription }
                    values["recording"] = recorded.path
                    values["capture"] = stats.report()
                    if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: report), options: .atomic)
                        print(String(decoding: data, as: UTF8.self))
                    }
                    exit(passed ? 0 : 1)
                }
            }
        }
    }
}
