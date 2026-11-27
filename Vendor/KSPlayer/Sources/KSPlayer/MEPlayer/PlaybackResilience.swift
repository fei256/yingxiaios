import Foundation

public enum PlaybackAudioFailure {
    public static let domain = "KSPlayer.AudioOutput"
    public static func startup(_ underlying: NSError) -> NSError {
        NSError(domain: domain, code: 1, userInfo: [NSLocalizedDescriptionKey: "音频输出无法启动，请重试播放或切换音频设备。",
                                                   NSUnderlyingErrorKey: underlying])
    }
    public static func unavailable() -> NSError {
        NSError(domain: domain, code: 2, userInfo: [NSLocalizedDescriptionKey: "系统音频服务暂不可用，请稍后重试。"])
    }
    public static func isUnavailable(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == domain && error.code == 2
    }
}

/// A transport epoch shares a bounded attempt count across graph retries. Repeated state
/// sampling cannot restart the retry sequence or report its terminal error twice.
struct PlaybackAudioStarter {
    enum Outcome { case idle, running, retry(TimeInterval), failed(NSError) }
    private var epoch: UInt64?
    private var attempts = 0
    private var terminal = false
    mutating func reset() { epoch = nil; attempts = 0; terminal = false }
    mutating func attempt(revision: UInt64, allowed: Bool, running: Bool,
                          start: () throws -> Void) -> Outcome {
        guard allowed else { reset(); return .idle }
        if epoch != revision { epoch = revision; attempts = 0; terminal = false }
        if running { attempts = 0; terminal = false; return .running }
        guard !terminal else { return .idle }
        attempts += 1
        do { try start(); attempts = 0; return .running }
        catch {
            if attempts < 3 { return .retry(attempts == 1 ? 0.05 : 0.2) }
            terminal = true
            return .failed(error as NSError)
        }
    }
}

/// System reset preserves context, but availability and a user transport command
/// must both permit resumption. Duplicate notifications keep the first snapshot.
public struct PlaybackUserResumeGate<Context: Sendable> {
    public private(set) var context: Context?
    public private(set) var available = true
    public init() {}
    public mutating func suspend(context: Context?, available: Bool) {
        if self.context == nil { self.context = context }
        self.available = available
    }
    public var userResumeContext: Context? { available ? context : nil }
    public mutating func clearPending() { context = nil }
}

/// Reservations follow the actual packet lifetime, including a native decoder's
/// in-flight callback. Primary and companion demuxers share this budget.
public final class PlaybackPacketBudget: @unchecked Sendable {
    public enum Decision { case read, pause, stalled }
    public final class Reservation: @unchecked Sendable {
        private let budget: PlaybackPacketBudget
        private let owner: UUID
        private let track: String
        private let bytes: Int
        fileprivate init(budget: PlaybackPacketBudget, owner: UUID, track: String, bytes: Int) {
            self.budget = budget; self.owner = owner; self.track = track; self.bytes = bytes
        }
        deinit { budget.release(owner: owner, track: track, bytes: bytes) }
    }
    private final class Owner {
        var registered = true
        var ready = false
        var bytes = 0
        var tracks: [String: Int] = [:]
        var trackCount = 1
        var paused = false
    }
    private let lock = NSLock()
    private var owners: [UUID: Owner] = [:]
    private var total = 0
    private var active = false
    private var outputReady = false
    private var stalledSince: TimeInterval?
    private var reportedStall = false
    public let maximumBytes: Int
    public let maximumPacketBytes: Int
    public let stallTimeout: TimeInterval

    public init(maximumBytes: Int = ProcessInfo.processInfo.physicalMemory >= 6 * 1024 * 1024 * 1024 ? 192 * 1024 * 1024 : 128 * 1024 * 1024,
                maximumPacketBytes: Int = 32 * 1024 * 1024, stallTimeout: TimeInterval = 20) {
        precondition(maximumPacketBytes > 0 && maximumBytes >= maximumPacketBytes * 2 && stallTimeout > 0)
        self.maximumBytes = maximumBytes; self.maximumPacketBytes = maximumPacketBytes; self.stallTimeout = stallTimeout
    }
    public func registerOwner() -> UUID {
        lock.withLock { let id = UUID(); owners[id] = Owner(); return id }
    }
    public func setTrackCount(_ count: Int, owner: UUID) {
        lock.withLock { owners[owner]?.trackCount = max(1, count) }
    }
    public func unregisterOwner(_ id: UUID) {
        lock.withLock {
            guard let owner = owners[id] else { return }
            owner.registered = false
            if owner.bytes == 0 { owners[id] = nil }
            stalledSince = nil
        }
    }
    public var bytes: Int { lock.withLock { total } }
    private var registeredCount: Int { max(1, owners.values.filter(\.registered).count) }
    private func highWater() -> Int {
        max(1, (maximumBytes - maximumPacketBytes * registeredCount) / registeredCount)
    }
    private func pressured(_ owner: Owner) -> Bool {
        let high = highWater(), trackHigh = max(1, high / owner.trackCount)
        if owner.bytes >= high || owner.tracks.values.contains(where: { $0 >= trackHigh }) { owner.paused = true }
        else if owner.bytes < high / 2 && owner.tracks.values.allSatisfy({ $0 < max(1, trackHigh / 2) }) { owner.paused = false }
        return owner.paused
    }
    public var hasPressure: Bool { lock.withLock { owners.values.filter(\.registered).contains(where: pressured) } }
    public func shouldPause(owner id: UUID) -> Bool {
        lock.withLock { owners[id].map(pressured) ?? false }
    }
    public func reserve(owner id: UUID, track: String, bytes: Int) -> Reservation? {
        guard bytes > 0, bytes <= maximumPacketBytes else { return nil }
        let accepted = lock.withLock {
            guard let owner = owners[id], owner.registered,
                  total <= maximumBytes - bytes,
                  owner.bytes <= highWater() + maximumPacketBytes - bytes,
                  owner.tracks[track, default: 0] <= max(1, highWater() / owner.trackCount) + maximumPacketBytes - bytes else { return false }
            total += bytes; owner.bytes += bytes; owner.tracks[track, default: 0] += bytes
            _ = pressured(owner)
            return true
        }
        return accepted ? Reservation(budget: self, owner: id, track: track, bytes: bytes) : nil
    }
    private func release(owner id: UUID, track: String, bytes: Int) {
        lock.withLock {
            guard let owner = owners[id] else { return }
            total -= bytes; owner.bytes -= bytes; owner.tracks[track, default: 0] -= bytes
            if owner.tracks[track] == 0 { owner.tracks[track] = nil }
            if !owner.registered && owner.bytes == 0 { owners[id] = nil }
            else { _ = pressured(owner) }
        }
    }
    public func setPlaybackActive(_ value: Bool, outputReady: Bool = false) {
        lock.withLock {
            active = value; self.outputReady = outputReady
            if !value || outputReady { stalledSince = nil; reportedStall = false }
        }
    }
    public func resetProgress() {
        lock.withLock { stalledSince = nil; reportedStall = false }
    }
    public func decision(owner id: UUID, ready: Bool, now: TimeInterval) -> Decision {
        lock.withLock {
            guard let owner = owners[id], owner.registered else { return .read }
            owner.ready = ready
            let current = owners.values.filter(\.registered)
            let pressure = current.contains(where: pressured)
            if active && !outputReady && pressure && !current.allSatisfy(\.ready) {
                if stalledSince == nil { stalledSince = now }
                if !reportedStall, now - (stalledSince ?? now) >= stallTimeout {
                    reportedStall = true; return .stalled
                }
            } else { stalledSince = nil; reportedStall = false }
            return pressured(owner) ? .pause : .read
        }
    }
    public static func failure(stalled: Bool) -> NSError {
        NSError(domain: "KSPlayer.BufferBudget", code: stalled ? 2 : 1,
                userInfo: [NSLocalizedDescriptionKey: stalled
                    ? "当前音视频轨道无法完成缓冲，请切换音轨或播放线路。"
                    : "当前视频的缓冲数据过大，请切换线路或降低画质。"])
    }
    public static func videoFrames(width: Double, height: Double, live: Bool, physicalMemory: UInt64, tablet: Bool = false) -> UInt8 {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return live ? 4 : 16 }
        let ampleMemory = physicalMemory >= 6 * 1024 * 1024 * 1024
        // Keep the original display runway for up to 4K on higher-memory iPads.
        // At 60 fps two frames cover only 33 ms of decoder delivery jitter.
        if tablet && ampleMemory && max(width, height) <= 4096 && min(width, height) <= 2160 {
            return live ? 4 : 16
        }
        let budget = ampleMemory ? 96.0 * 1024 * 1024 : 64.0 * 1024 * 1024
        let estimated = width * height * 4
        guard estimated.isFinite, estimated > 0 else { return 2 }
        // The ring buffer rounds its input up to a power of two. Choose an
        // already rounded capacity so that allocation cannot exceed this estimate.
        let limit = min(live ? 4.0 : 16.0, floor(budget / estimated))
        return [16, 8, 4, 2].first(where: { Double($0) <= limit }).map(UInt8.init) ?? 2
    }
}
