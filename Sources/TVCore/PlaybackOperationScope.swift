import Foundation

public struct PlaybackOperationScope: Sendable {
    public struct Ticket: Equatable, Sendable { fileprivate let media: UUID; fileprivate let operation: UInt64 }
    private var media = UUID()
    private var operation: UInt64 = 0
    public init() {}
    public mutating func beginSeek() -> Ticket { operation &+= 1; return Ticket(media: media, operation: operation) }
    public mutating func replaceMedia() { media = UUID(); operation = 0 }
    public func accepts(_ ticket: Ticket) -> Bool { ticket.media == media && ticket.operation == operation }
}

public struct PlaybackStartupWork: Sendable {
    public enum Kind: Double, Hashable, Sendable {
        case subtitles = 1
        case remoteSkip = 0
        case danmaku = 4
    }
    private var stableSince: TimeInterval?
    private var hasHeadroom = true
    private var lastMediaTime: Double?
    private var advancedAt: TimeInterval?
    private var requested = Set<Kind>()
    public init() {}
    public mutating func observe(ready: Bool, now: TimeInterval) {
        if !ready { stableSince = nil }
        else if stableSince == nil { stableSince = now }
    }
    public mutating func observeProgress(ready: Bool, mediaTime: Double?, now: TimeInterval, stallTolerance: Double, hasHeadroom: Bool = true) {
        self.hasHeadroom = hasHeadroom
        guard ready, let mediaTime else {
            lastMediaTime = nil; advancedAt = nil; stableSince = nil
            return
        }
        if let last = lastMediaTime {
            if mediaTime < last || (advancedAt.map { now - $0 > stallTolerance } ?? false) {
                advancedAt = nil; stableSince = nil
            }
            if mediaTime > last { advancedAt = now }
        }
        lastMediaTime = mediaTime
        observe(ready: advancedAt != nil, now: now)
    }
    public func isRequested(_ kind: Kind) -> Bool { requested.contains(kind) }
    public mutating func endRequest(_ kind: Kind) { requested.remove(kind) }
    public mutating func request(_ kind: Kind) { requested.insert(kind) }
    public func allows(_ kind: Kind, now: TimeInterval) -> Bool {
        if requested.contains(kind) { return true }
        guard let stableSince else { return false }
        // Some sources expose little buffered time even when playback advances steadily.
        let extra: TimeInterval = hasHeadroom ? 0 : (kind == .remoteSkip ? 1 : 6)
        return now - stableSince >= kind.rawValue + extra
    }
}

public enum NextMediaPolicy {
    public static func mayPrepare(enabled: Bool, paused: Bool, buffering: Bool, seeking: Bool, bufferedSeconds: Double, speed: Double, remainingSeconds: Double? = nil) -> Bool {
        guard enabled, !paused, !buffering, !seeking, speed.isFinite, speed > 0, bufferedSeconds.isFinite, bufferedSeconds > 0 else { return false }
        if bufferedSeconds / speed >= 20 { return true }
        // Fully buffered to EOF: the current episode has no outstanding bytes to protect.
        guard let remainingSeconds, remainingSeconds.isFinite, remainingSeconds > 0 else { return false }
        return bufferedSeconds >= remainingSeconds
    }
}
