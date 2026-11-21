import Foundation

public protocol TimestampedQueueItem {
    var timestamp: Int64 { get }
}

enum MESourceState: Equatable {
    case idle, opening, opened, reading, seeking, paused, finished, closed, failed
}

enum MECodecState: Equatable {
    case idle, decoding, flush, closed, failed, finished
}

/// The reader holds this lock only to choose work. Network I/O and callbacks
/// run after a command has been returned and the condition has been unlocked.
final class PlaybackReaderCoordinator: @unchecked Sendable {
    typealias Completion = (Bool) -> Void
    struct Seek: Equatable {
        let revision: UInt64
        let time: TimeInterval
    }
    enum Command {
        case read(UInt64)
        case seek(Seek)
    }
    struct Snapshot {
        let state: MESourceState
        let seekTime: TimeInterval
        let revision: UInt64
    }
    struct EnqueuedSeek {
        let seek: Seek
        let restartReader: Bool
        let superseded: Completion?
    }
    struct Closing {
        let completion: Completion?
    }

    private let condition = NSCondition()
    private var sourceState = MESourceState.idle
    private var revision: UInt64 = 0
    private var target: TimeInterval = 0
    private var completion: Completion?
    private var readerSequence: UInt64 = 0
    private var readerReservation: UInt64?

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(state: sourceState, seekTime: target, revision: revision)
    }

    @discardableResult
    func transition(from allowed: [MESourceState], to next: MESourceState, revision expected: UInt64? = nil) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard sourceState != .closed, sourceState != next, allowed.contains(sourceState),
              expected == nil || expected == revision else { return false }
        sourceState = next
        condition.broadcast()
        return true
    }

    func reserveReader() -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        guard readerReservation == nil, [.opened, .reading, .seeking, .paused].contains(sourceState) else { return nil }
        readerSequence &+= 1
        readerReservation = readerSequence
        return readerSequence
    }

    func releaseReader(_ reservation: UInt64) {
        condition.lock()
        defer { condition.unlock() }
        if readerReservation == reservation { readerReservation = nil }
    }

    func nextCommand(reader reservation: UInt64) -> Command? {
        condition.lock()
        defer { condition.unlock() }
        guard readerReservation == reservation else { return nil }
        while sourceState == .paused { condition.wait() }
        switch sourceState {
        case .reading: return .read(revision)
        case .seeking: return .seek(Seek(revision: revision, time: target))
        default:
            readerReservation = nil
            return nil
        }
    }

    func enqueueSeek(time: TimeInterval, completion next: @escaping Completion) -> EnqueuedSeek? {
        condition.lock()
        defer { condition.unlock() }
        guard time.isFinite, [.reading, .paused, .seeking, .finished].contains(sourceState) else { return nil }
        let restart = readerReservation == nil
        let previous = completion
        revision &+= 1
        target = max(0, time)
        completion = next
        sourceState = .seeking
        condition.broadcast()
        return EnqueuedSeek(seek: Seek(revision: revision, time: target), restartReader: restart, superseded: previous)
    }

    func accepts(_ seek: Seek) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return sourceState == .seeking && seek.revision == revision
    }

    func acceptsRead(revision expected: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return expected == revision && (sourceState == .reading || sourceState == .paused)
    }

    func finishSeek(_ seek: Seek) -> Completion? {
        condition.lock()
        defer { condition.unlock() }
        guard sourceState == .seeking, seek.revision == revision else { return nil }
        let finished = completion
        completion = nil
        sourceState = .reading
        condition.broadcast()
        return finished
    }

    func close() -> Closing? {
        condition.lock()
        defer { condition.unlock() }
        guard sourceState != .closed else { return nil }
        sourceState = .closed
        revision &+= 1
        let closing = completion
        completion = nil
        condition.broadcast()
        return Closing(completion: closing)
    }
}

/// Native callbacks only look up identities here. Creation, replacement and
/// release belong to the track's decode worker; no native call holds this lock.
final class PlaybackResourceRegistry<Key: Hashable, Resource>: @unchecked Sendable {
    private let lock = NSLock()
    private var resources: [Key: Resource] = [:]

    func value(for key: Key) -> Resource? { lock.withLock { resources[key] } }

    func value(for key: Key, creating create: () -> Resource) -> Resource {
        if let existing = value(for: key) { return existing }
        let created = create()
        return lock.withLock {
            if let existing = resources[key] { return existing }
            resources[key] = created
            return created
        }
    }

    func replace(_ value: Resource, for key: Key) { lock.withLock { resources[key] = value } }
    var values: [Resource] { lock.withLock { Array(resources.values) } }
    func takeAll() -> [Resource] {
        lock.withLock {
            let removed = Array(resources.values)
            resources.removeAll()
            return removed
        }
    }
}

final class PlaybackEventMailbox<Event>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []
    var hasEvents: Bool { lock.withLock { !events.isEmpty } }
    func append(_ event: Event) { lock.withLock { events.append(event) } }
    func takeAll() -> [Event] {
        lock.withLock {
            let pending = events
            events.removeAll(keepingCapacity: true)
            return pending
        }
    }
}

final class PlaybackTrackState: @unchecked Sendable {
    private let lock = NSLock()
    private var codecState = MECodecState.idle
    private var target = 0.0
    private var ended = false
    var state: MECodecState { lock.withLock { codecState } }
    var seekTime: TimeInterval {
        get { lock.withLock { target } }
        set { lock.withLock { if codecState != .closed { target = newValue } } }
    }
    var isEndOfFile: Bool {
        get { lock.withLock { ended } }
        set { lock.withLock { ended = newValue } }
    }

    @discardableResult func transition(to next: MECodecState) -> Bool {
        lock.withLock {
            guard codecState != .closed else { return false }
            codecState = next
            if next == .finished { target = 0 }
            return true
        }
    }

    func seek(to time: TimeInterval) {
        lock.withLock {
            guard codecState != .closed else { return }
            target = time
            ended = false
            codecState = .flush
        }
    }
}

/// Volume survives node replacement. A queued graph restart uses the transport
/// revision so a later pause or interruption cannot restart output accidentally.
struct PlaybackAudioOutputIntent {
    private(set) var volume: Float = 1
    private(set) var wantsPlaying = false
    private(set) var interrupted = false
    private(set) var revision: UInt64 = 0
    var canRun: Bool { wantsPlaying && !interrupted }

    mutating func setVolume(_ value: Float) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
    }
    mutating func setPlaying(_ value: Bool) {
        wantsPlaying = value
        revision &+= 1
    }
    mutating func setInterrupted(_ value: Bool) {
        interrupted = value
        revision &+= 1
    }
    func acceptsRestart(revision expected: UInt64) -> Bool { expected == revision && canRun }
}
