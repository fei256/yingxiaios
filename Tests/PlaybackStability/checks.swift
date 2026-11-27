import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}

private struct QueueItem: TimestampedQueueItem, Sendable {
    let timestamp: Int64
}

private final class Resource: @unchecked Sendable {
    let id: Int
    private let releases = Locked(0)
    init(_ id: Int) { self.id = id }
    func shutdown() { releases.update { $0 += 1 } }
    var releaseCount: Int { releases.value }
}

@main enum PlaybackStabilityChecks {
    static func require(_ result: @autoclosure () -> Bool, _ message: String) throws {
        if !result() { throw Failure(description: message) }
    }
    static func awaitSignal(_ semaphore: DispatchSemaphore, _ message: String) throws {
        try require(semaphore.wait(timeout: .now() + 5) == .success, message)
    }
    static func readyReader() -> (PlaybackReaderCoordinator, UInt64) {
        let reader = PlaybackReaderCoordinator()
        precondition(reader.transition(from: [.idle], to: .opening))
        precondition(reader.transition(from: [.opening], to: .opened))
        let reservation = reader.reserveReader()!
        precondition(reader.transition(from: [.opened], to: .reading))
        return (reader, reservation)
    }

    static func main() throws {
        var count = 0
        func check(_ name: String, _ body: () throws -> Void) throws {
            try body()
            count += 1
            print("Playback stability: \(name) passed")
        }

        try check("resume before wait does not lose a wakeup") {
            let (reader, reservation) = readyReader()
            reader.transition(from: [.reading], to: .paused)
            reader.transition(from: [.paused], to: .reading)
            let finished = DispatchSemaphore(value: 0)
            let read = Locked(false)
            DispatchQueue.global().async {
                if case .read(_)? = reader.nextCommand(reader: reservation) { read.update { $0 = true } }
                finished.signal()
            }
            try awaitSignal(finished, "A resume delivered before wait left the reader asleep")
            try require(read.value, "The resumed reader did not choose a read command")
            _ = reader.close()
        }

        try check("pause/resume and close wake the same predicate") {
            for iteration in 0..<300 {
                let (reader, reservation) = readyReader()
                reader.transition(from: [.reading], to: .paused)
                let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
                let result = Locked(false)
                DispatchQueue.global().async {
                    started.signal()
                    let command = reader.nextCommand(reader: reservation)
                    if iteration.isMultiple(of: 2) {
                        if case .read(_)? = command { result.update { $0 = true } }
                    } else if command == nil { result.update { $0 = true } }
                    finished.signal()
                }
                try awaitSignal(started, "The reader worker did not start")
                if iteration.isMultiple(of: 2) { reader.transition(from: [.paused], to: .reading) }
                else { _ = reader.close() }
                try awaitSignal(finished, "A paused reader missed resume/close")
                try require(result.value, "The reader chose work after close or failed to resume")
                _ = reader.close()
                try require(!reader.transition(from: [.closed], to: .reading), "A late transition revived a closed input")
            }
        }

        try check("superseded seek callbacks detach and may reenter") {
            let (reader, reservation) = readyReader()
            let replies = Locked([Bool]())
            let first = reader.enqueueSeek(time: 10) { value in replies.update { $0.append(value) } }!
            let second = reader.enqueueSeek(time: 20) { value in
                replies.update { $0.append(value) }
                _ = reader.enqueueSeek(time: 30) { _ in }
            }!
            second.superseded?(false)
            try require(!reader.accepts(first.seek), "An old seek retained ownership")
            try require(reader.finishSeek(first.seek) == nil, "An old seek consumed the new callback")
            guard case let .seek(command)? = reader.nextCommand(reader: reservation) else { throw Failure(description: "The seek command was lost") }
            try require(command.time == 20, "The reader did not use the latest target")
            let finished = reader.finishSeek(command)
            finished?(true)
            try require(replies.value == [false, true], "Seek completion was missing or duplicated")
            try require(reader.snapshot.state == .seeking && reader.snapshot.seekTime == 30, "Reentrant completion lost the next seek")
            let closing = reader.close()
            closing?.completion?(false)
            try require(reader.close() == nil, "Closing was not idempotent")
        }

        try check("EOF seek hands off exactly one reader reservation") {
            let (reader, oldReservation) = readyReader()
            reader.transition(from: [.reading], to: .finished)
            let inFlight = reader.enqueueSeek(time: 4) { _ in }!
            try require(!inFlight.restartReader, "A still-running reader was duplicated at EOF")
            guard case let .seek(command)? = reader.nextCommand(reader: oldReservation) else { throw Failure(description: "The active reader missed an EOF seek") }
            reader.finishSeek(command)?(true)
            reader.transition(from: [.reading], to: .finished)
            try require(reader.nextCommand(reader: oldReservation) == nil, "An ended reader did not release ownership")
            let next = reader.enqueueSeek(time: 8) { _ in }!
            try require(next.restartReader, "A seek after reader exit did not restart it")
            let newReservation = reader.reserveReader()!
            reader.releaseReader(oldReservation)
            try require(reader.reserveReader() == nil, "A stale exit released a newer reader")
            guard case let .seek(restarted)? = reader.nextCommand(reader: newReservation) else { throw Failure(description: "The replacement reader lost its command") }
            try require(restarted.time == 8, "The replacement reader used an old epoch")
            _ = reader.close()
        }

        try check("tablet UHD queue covers a 100 ms decoder delivery gap at 60 fps") {
            let memory: UInt64 = 8 * 1024 * 1024 * 1024
            func missedPictures(tablet: Bool) -> Int {
                let capacity = PlaybackPacketBudget.videoFrames(width: 3840, height: 2160, live: false,
                                                               physicalMemory: memory, tablet: tablet)
                let queue = CircularBuffer<QueueItem>(initialCapacity: Int(capacity), sorted: true, expanding: false)
                for index in 0..<Int(capacity) { queue.push(QueueItem(timestamp: Int64(index))) }
                // Six display deadlines elapse before the decoder delivers its next batch.
                return (0..<6).filter { _ in queue.pop() == nil }.count
            }
            try require(missedPictures(tablet: false) == 4, "Two-frame control did not exercise starvation")
            try require(missedPictures(tablet: true) == 0, "Tablet VOD ran out of decoded frames")
            try require(PlaybackPacketBudget.videoFrames(width: 2160, height: 3840, live: false,
                        physicalMemory: memory, tablet: true) == 16, "Portrait UHD lost its display runway")
            try require(PlaybackPacketBudget.videoFrames(width: 3840, height: 2160, live: true,
                        physicalMemory: memory, tablet: true) == 4, "Live playback inherited the VOD queue")
            try require(PlaybackPacketBudget.videoFrames(width: 7680, height: 4320, live: false,
                        physicalMemory: memory, tablet: true) == 2, "8K bypassed the large-frame memory limit")
            try require(PlaybackPacketBudget.videoFrames(width: 3840, height: 2160, live: false,
                        physicalMemory: memory / 2, tablet: true) == 2, "Lower-memory tablets bypassed their budget")
        }
        try check("bounded frame queue waits before writing a full slot") {
            let queue = CircularBuffer<QueueItem>(initialCapacity: 2, expanding: false)
            queue.push(QueueItem(timestamp: 1)); queue.push(QueueItem(timestamp: 2))
            let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                started.signal()
                queue.push(QueueItem(timestamp: 3))
                finished.signal()
            }
            try awaitSignal(started, "The frame producer did not start")
            try require(finished.wait(timeout: .now() + 0.02) == .timedOut, "A full frame queue overwrote a live slot")
            try require(queue.count == 2 && queue.pop()?.timestamp == 1, "The full frame queue lost its head")
            try awaitSignal(finished, "Consuming a frame did not release the producer")
            try require(queue.pop()?.timestamp == 2 && queue.pop()?.timestamp == 3, "Queued frames lost order")
            queue.shutdown()
        }

        try check("seek flush rejects a producer from the previous generation") {
            let queue = CircularBuffer<QueueItem>(initialCapacity: 1, expanding: false)
            let generation = queue.generation
            queue.push(QueueItem(timestamp: 1), generation: generation)
            let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                started.signal()
                queue.push(QueueItem(timestamp: 2), generation: generation)
                finished.signal()
            }
            try awaitSignal(started, "The stale frame producer did not start")
            queue.flush(advanceGeneration: true)
            try awaitSignal(finished, "Seek flush did not wake a full-queue producer")
            try require(queue.count == 0, "A pre-seek callback refilled the replacement timeline")
            queue.push(QueueItem(timestamp: 3), generation: queue.generation)
            try require(queue.pop()?.timestamp == 3, "The new seek generation was rejected")
            queue.shutdown()
        }

        try check("shutdown releases blocked consumers and producers") {
            let empty = CircularBuffer<QueueItem>()
            let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            let received = Locked<QueueItem?>(nil)
            DispatchQueue.global().async {
                started.signal()
                received.update { $0 = empty.pop(wait: true) }
                finished.signal()
            }
            try awaitSignal(started, "The packet consumer did not start")
            empty.shutdown(); empty.shutdown()
            try awaitSignal(finished, "Shutdown left the packet consumer asleep")
            try require(received.value == nil, "A closed packet queue yielded data")
            let full = CircularBuffer<QueueItem>(initialCapacity: 1, expanding: false)
            full.push(QueueItem(timestamp: 1))
            DispatchQueue.global().async { full.push(QueueItem(timestamp: 2)); finished.signal() }
            full.shutdown()
            try awaitSignal(finished, "Shutdown left a frame callback asleep")
            full.flush(); full.push(QueueItem(timestamp: 3))
            try require(full.count == 0, "A flush reopened a destroyed frame queue")
        }

        try check("stale frame callbacks cannot publish buffering FPS") {
            let queue = CircularBuffer<QueueItem>()
            let previous = queue.generation
            queue.flush(advanceGeneration: true)
            try require(queue.setFPS(60, ifGeneration: queue.generation), "Current FPS metadata was rejected")
            try require(!queue.setFPS(24, ifGeneration: previous) && queue.fps == 60,
                        "A callback from the old timeline overwrote current buffering FPS")
            queue.shutdown()
        }

        try check("native error mailbox interrupts an empty packet wait") {
            for beforeWait in [true, false] {
                let queue = CircularBuffer<QueueItem>()
                let events = PlaybackEventMailbox<Int>()
                let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
                let interrupted = Locked(false)
                if beforeWait { events.append(7); queue.wake() }
                DispatchQueue.global().async {
                    started.signal()
                    let packet = queue.pop(wait: true, interrupted: { events.hasEvents })
                    interrupted.update { $0 = packet == nil && events.takeAll() == [7] }
                    finished.signal()
                }
                try awaitSignal(started, "The error wait worker did not start")
                if !beforeWait { events.append(7); queue.wake() }
                try awaitSignal(finished, "A decode error waited forever for another media packet")
                try require(interrupted.value, "A decoder error was not delivered to its worker")
                queue.shutdown()
            }
        }

        try check("concurrent queue count snapshots cannot underflow") {
            let queue = CircularBuffer<QueueItem>(initialCapacity: 64, expanding: false)
            let group = DispatchGroup(), ordered = Locked(true)
            group.enter()
            DispatchQueue.global().async {
                for value in 0..<20_000 { queue.push(QueueItem(timestamp: Int64(value))) }
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                for value in 0..<20_000 {
                    if queue.pop(wait: true)?.timestamp != Int64(value) { ordered.update { $0 = false } }
                }
                group.leave()
            }
            for _ in 0..<100_000 {
                try require((0...64).contains(queue.count), "A count snapshot violated bounded queue capacity")
            }
            try require(group.wait(timeout: .now() + 30) == .success, "Concurrent queue workers stopped making progress")
            try require(ordered.value && queue.count == 0, "Concurrent queue traffic lost data")
            queue.shutdown()
        }

        try check("concurrent native frame producers retain every queue slot") {
            let queue = CircularBuffer<QueueItem>(initialCapacity: 1, sorted: true, expanding: false)
            let group = DispatchGroup(), unique = Locked(Set<Int64>())
            group.enter()
            DispatchQueue.global().async {
                var found = Set<Int64>()
                for _ in 0..<4_000 { if let item = queue.pop(wait: true) { found.insert(item.timestamp) } }
                unique.update { $0 = found }
                group.leave()
            }
            for producer in 0..<4 {
                group.enter()
                DispatchQueue.global().async {
                    for value in 0..<1_000 { queue.push(QueueItem(timestamp: Int64(producer * 1_000 + value))) }
                    group.leave()
                }
            }
            try require(group.wait(timeout: .now() + 30) == .success, "Native-style producers remained blocked")
            try require(unique.value.count == 4_000 && queue.count == 0, "Concurrent frame producers overwrote ring slots")
            queue.shutdown()
        }

        try check("decoder identities replace atomically and release once") {
            let registry = PlaybackResourceRegistry<Int, Resource>()
            let old = registry.value(for: 1, creating: { Resource(1) })
            try require(registry.value(for: 1) === old, "The decoder callback identity was not registered")
            let replacement = Resource(2)
            registry.replace(replacement, for: 1)
            try require(registry.value(for: 1) !== old, "An old callback still owned the replacement decoder")
            old.shutdown()
            registry.takeAll().forEach { $0.shutdown() }
            registry.takeAll().forEach { $0.shutdown() }
            try require(old.releaseCount == 1 && replacement.releaseCount == 1, "The close registry released a native resource twice")
        }

        try check("closed codec state cannot be revived by seek or worker startup") {
            let state = PlaybackTrackState()
            state.transition(to: .decoding)
            state.isEndOfFile = true
            state.seek(to: 42)
            try require(state.state == .flush && !state.isEndOfFile && state.seekTime == 42, "A seek did not reset the codec timeline")
            state.transition(to: .closed)
            state.seek(to: 84)
            try require(!state.transition(to: .decoding) && state.state == .closed && state.seekTime == 42,
                        "A queued decode operation revived a closed codec")
        }

        try check("volume survives prepare and graph retry honors newer pause") {
            var intent = PlaybackAudioOutputIntent()
            intent.setVolume(0.2)
            try require(abs(intent.volume - 0.2) < 0.0001, "A pre-prepare volume setting was lost")
            intent.setPlaying(true)
            let retry = intent.revision
            intent.setPlaying(false)
            try require(!intent.acceptsRestart(revision: retry) && !intent.canRun, "A queued graph retry ignored user pause")
            try require(abs(intent.volume - 0.2) < 0.0001, "Rebuilding transport reset volume")
            intent.setVolume(.nan)
            try require(abs(intent.volume - 0.2) < 0.0001, "An invalid volume replaced the user's setting")
        }

        try check("interruption and manual pause gate configuration recovery") {
            var intent = PlaybackAudioOutputIntent()
            intent.setPlaying(true)
            let retry = intent.revision
            intent.setInterrupted(true)
            try require(!intent.canRun && !intent.acceptsRestart(revision: retry), "A graph restart ran during interruption")
            intent.setInterrupted(false)
            try require(intent.canRun, "A valid resumption lost playback intent")
            intent.setInterrupted(true)
            intent.setPlaying(false)
            intent.setInterrupted(false)
            try require(!intent.canRun, "Ending interruption overrode a user pause")
        }
        print("Playback stability: all \(count) production-component checks passed")
    }
}
