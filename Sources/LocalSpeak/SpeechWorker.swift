import Foundation

// Pipe callbacks are serialised here; UI events are delivered on the main actor.
private final class LineReader {
    private var data = Data()
    private let lock = NSLock()
    func append(_ bytes: Data) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
        var events: [[String: Any]] = []
        while let end = data.firstIndex(of: 10) {
            let line = data[..<end]
            data.removeSubrange(...end)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { events.append(object) }
        }
        return events
    }
}

@MainActor protocol SpeechWorking: AnyObject {
    var onEvent: (([String: Any]) -> Void)? { get set }
    func start(device: String) throws
    func synthesize(_ job: SpeechJob) throws
    func cancel(_ id: String)
    func stop()
}

@MainActor final class SpeechWorker: SpeechWorking {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var token = UUID()
    var onEvent: (([String: Any]) -> Void)?

    func start(device: String) throws {
        stop()
        let python = Paths.runtime.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw LocalError("The speech runtime is missing. Run scripts/setup.sh from the project folder, then restart the engine.")
        }
        try FileManager.default.createDirectory(at: Paths.session, withIntermediateDirectories: true)
        let logURL = Paths.runtime.appendingPathComponent("logs/engine.log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        try log.write(contentsOf: Data("\n--- Engine start \(Date()) device=\(device) ---\n".utf8))
        let p = Process(), stdin = Pipe(), stdout = Pipe(), reader = LineReader()
        let currentToken = UUID(); token = currentToken
        p.executableURL = python
        p.arguments = ["-u", Paths.root.appendingPathComponent("engine/worker.py").path,
                       "--root", Paths.root.path, "--device", device, "--output", Paths.session.path]
        p.currentDirectoryURL = Paths.root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        env["OMP_NUM_THREADS"] = "6"
        env["GRADIO_ANALYTICS_ENABLED"] = "False"
        p.environment = env
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = log
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            for event in reader.append(chunk) {
                DispatchQueue.main.async {
                    guard let self, self.token == currentToken else { return }
                    self.onEvent?(event)
                }
            }
        }
        p.terminationHandler = { [weak self] p in
            try? log.close()
            DispatchQueue.main.async {
                guard let self, self.token == currentToken else { return }
                self.onEvent?(["type": "exit", "message": "Speech engine stopped (\(p.terminationStatus)). Open engine log for details."])
            }
        }
        try p.run()
        process = p; input = stdin; output = stdout
    }

    func send(_ command: [String: Any]) throws {
        guard process?.isRunning == true, let input else { throw LocalError("The speech engine is not running.") }
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func synthesize(_ job: SpeechJob) throws {
        let encoded = try JSONEncoder().encode(job.voice)
        let voice = try JSONSerialization.jsonObject(with: encoded)
        try send(["type": "synthesize", "id": job.id, "text": job.text, "language": job.language,
                  "speed": job.speed, "voice": voice])
    }

    func cancel(_ id: String) { try? send(["type": "cancel", "id": id]) }

    func stop() {
        token = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning {
            try? send(["type": "shutdown"])
            p.terminate()
        }
        try? input?.fileHandleForWriting.close()
        process = nil; input = nil; output = nil
    }
}

