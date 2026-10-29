import Foundation

enum Diagnostics {
    private static let lock = NSLock()
    static func audio(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let url = Paths.runtime.appendingPathComponent("logs/audio.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) \(message)\n".utf8))
        try? handle.close()
    }
}
