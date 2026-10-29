import Foundation

struct PlaybackProgress {
    private(set) var pending: Set<UUID> = []
    private(set) var generationFinished = false
    private(set) var expectedEnd: TimeInterval = 0
    var isFinished: Bool { generationFinished && pending.isEmpty }
    mutating func add(_ ticket: UUID, seconds: Double, now: TimeInterval, margin: TimeInterval = 8) -> TimeInterval {
        pending.insert(ticket)
        expectedEnd = max(now, expectedEnd) + max(0, seconds)
        return expectedEnd + margin // startup, driver latency, and scheduling margin
    }
    @discardableResult mutating func settle(_ ticket: UUID) -> Bool { pending.remove(ticket) != nil }
    mutating func generated() { generationFinished = true }
}
