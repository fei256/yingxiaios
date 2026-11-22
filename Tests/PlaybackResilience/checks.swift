import Foundation

private struct Failure: Error { let message: String }
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func update(_ action: (inout Value) -> Void) { lock.withLock { action(&value) } }
    var snapshot: Value { lock.withLock { value } }
}

@main enum PlaybackResilienceChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func main() throws {
        var results: [[String: Any]] = []
        func check(_ name: String, _ action: () throws -> Void) throws {
            try action(); results.append(["name": name, "passed": true]); print("PASS \(name)")
        }
        let error = NSError(domain: "fixture", code: 91)
        try check("transient audio startup retries and retains successful output") {
            var starter = PlaybackAudioStarter(), calls = 0
            func start() throws { calls += 1; if calls == 1 { throw error } }
            if case .retry = starter.attempt(revision: 1, allowed: true, running: false, start: start) {} else { throw Failure(message: "Transient error was terminal") }
            if case .running = starter.attempt(revision: 1, allowed: true, running: false, start: start) {} else { throw Failure(message: "The retry did not start") }
            _ = starter.attempt(revision: 1, allowed: true, running: true, start: start)
            try require(calls == 2, "A running output was started again")
        }
        try check("persistent audio error reports once after three actual attempts") {
            var starter = PlaybackAudioStarter(), calls = 0, failures = 0
            for _ in 0..<10 {
                let result = starter.attempt(revision: 7, allowed: true, running: false) { calls += 1; throw error }
                if case let .failed(failure) = result { failures += 1; try require(failure.code == 91, "Underlying error disappeared") }
            }
            try require(calls == 3 && failures == 1, "Sampling bypassed the retry budget")
        }
        try check("pause prevents an audio retry and a user resume starts a new epoch") {
            var starter = PlaybackAudioStarter(), calls = 0
            _ = starter.attempt(revision: 1, allowed: true, running: false) { calls += 1; throw error }
            _ = starter.attempt(revision: 2, allowed: false, running: false) { calls += 1 }
            try require(calls == 1, "A paused graph attempted a start")
            if case .running = starter.attempt(revision: 3, allowed: true, running: false, start: { calls += 1 }) {} else { throw Failure(message: "User resume remained poisoned") }
            try require(calls == 2, "The new user intent did not run exactly once")
        }
        try check("audio failure preserves its native error identity") {
            let failure = PlaybackAudioFailure.startup(error)
            try require(failure.domain == PlaybackAudioFailure.domain && failure.code == 1,
                        "The session cannot classify the audio failure")
            try require((failure.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == 91, "The underlying hardware code was lost")
            try require(PlaybackAudioFailure.isUnavailable(PlaybackAudioFailure.unavailable()), "Unavailable media services were treated as an automatic retry")
        }
        try check("shared packet leases cap the primary and companion input together") {
            let budget = PlaybackPacketBudget(maximumBytes: 1024, maximumPacketBytes: 128)
            let a = budget.registerOwner(), b = budget.registerOwner()
            var leases: [PlaybackPacketBudget.Reservation] = []
            for owner in [a, b] {
                for _ in 0..<4 { guard let lease = budget.reserve(owner: owner, track: "media", bytes: 128) else { throw Failure(message: "One admitted in-flight packet was rejected") }; leases.append(lease) }
            }
            try require(budget.bytes == 1024 && budget.reserve(owner: a, track: "media", bytes: 1) == nil, "The shared hard limit was exceeded")
            leases.removeAll()
            try require(budget.bytes == 0, "Closed packet leases retained memory credit")
        }
        try check("one track applies pressure while its missing partner remains unready") {
            let budget = PlaybackPacketBudget(maximumBytes: 1024, maximumPacketBytes: 128, stallTimeout: 2)
            let owner = budget.registerOwner(); budget.setTrackCount(2, owner: owner)
            var leases: [PlaybackPacketBudget.Reservation] = []
            for _ in 0..<4 { leases.append(budget.reserve(owner: owner, track: "video", bytes: 112)!) }
            try require(budget.shouldPause(owner: owner) && budget.hasPressure, "An unready audio track bypassed video byte pressure")
            budget.setPlaybackActive(true)
            if case .pause = budget.decision(owner: owner, ready: false, now: 10) {} else { throw Failure(message: "Reader was not paused") }
            if case .stalled = budget.decision(owner: owner, ready: false, now: 12.1) {} else { throw Failure(message: "Unready input retained its full queue forever") }
            leases.removeAll()
        }
        try check("user pause and output playback suppress buffering starvation failures") {
            let budget = PlaybackPacketBudget(maximumBytes: 512, maximumPacketBytes: 128, stallTimeout: 1)
            let owner = budget.registerOwner()
            var leases = [budget.reserve(owner: owner, track: "video", bytes: 128)!, budget.reserve(owner: owner, track: "video", bytes: 128)!, budget.reserve(owner: owner, track: "video", bytes: 128)!]
            budget.setPlaybackActive(false)
            if case .stalled = budget.decision(owner: owner, ready: false, now: 100) { throw Failure(message: "User pause became an input failure") }
            budget.setPlaybackActive(true, outputReady: true)
            _ = budget.decision(owner: owner, ready: false, now: 101)
            if case .stalled = budget.decision(owner: owner, ready: false, now: 200) { throw Failure(message: "A momentary frame count sample failed playing output") }
            leases.removeAll()
        }
        try check("seek resets the pressure deadline without forgetting live packet bytes") {
            let budget = PlaybackPacketBudget(maximumBytes: 512, maximumPacketBytes: 128, stallTimeout: 2)
            let owner = budget.registerOwner()
            var leases = [budget.reserve(owner: owner, track: "video", bytes: 128)!, budget.reserve(owner: owner, track: "video", bytes: 128)!, budget.reserve(owner: owner, track: "video", bytes: 128)!]
            budget.setPlaybackActive(true); _ = budget.decision(owner: owner, ready: false, now: 10)
            budget.resetProgress()
            _ = budget.decision(owner: owner, ready: false, now: 50)
            if case .stalled = budget.decision(owner: owner, ready: false, now: 51) { throw Failure(message: "Seek inherited an old timeout") }
            try require(budget.bytes == 384, "Seek forgot still-retained native packets")
            leases.removeAll()
        }
        try check("decoder-held packets release their budget only after the callback retires") {
            let budget = PlaybackPacketBudget(maximumBytes: 512, maximumPacketBytes: 128)
            let owner = budget.registerOwner()
            var queued = [budget.reserve(owner: owner, track: "video", bytes: 128)!]
            var callback: PlaybackPacketBudget.Reservation? = queued[0]
            queued.removeAll(); budget.unregisterOwner(owner)
            try require(budget.bytes == 128 && callback != nil, "Removing a queue slot forgot in-flight decoder memory")
            try require(budget.reserve(owner: owner, track: "video", bytes: 1) == nil, "A closed owner admitted a new packet")
            callback = nil
            try require(budget.bytes == 0, "Retiring the callback leaked a reservation")
        }
        try check("oversized packets are rejected before queue admission") {
            let budget = PlaybackPacketBudget(maximumBytes: 512, maximumPacketBytes: 128)
            let owner = budget.registerOwner()
            try require(budget.reserve(owner: owner, track: "video", bytes: 129) == nil && budget.bytes == 0, "An oversized packet exceeded its allocation bound")
        }
        try check("concurrent packet owners cannot exceed or underflow the shared counter") {
            let budget = PlaybackPacketBudget(maximumBytes: 4096, maximumPacketBytes: 128)
            let owners = [budget.registerOwner(), budget.registerOwner()], maximum = Locked(0)
            let group = DispatchGroup()
            for lane in 0..<4 {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<1000 {
                        if let lease = budget.reserve(owner: owners[lane % 2], track: "media", bytes: 64) {
                            maximum.update { $0 = max($0, budget.bytes) }
                            withExtendedLifetime(lease) {}
                        }
                    }
                    group.leave()
                }
            }
            try require(group.wait(timeout: .now() + 15) == .success, "Budget ownership remained blocked")
            try require(budget.bytes == 0 && maximum.snapshot <= 4096, "Concurrent accounting lost packet lifetime")
        }
        try check("high-resolution frame queues shrink while small video retains its prebuffer") {
            let memory: UInt64 = 4 * 1024 * 1024 * 1024
            try require(PlaybackPacketBudget.videoFrames(width: 640, height: 360, live: false, physicalMemory: memory) == 16, "Small video unnecessarily lost queue depth")
            try require(PlaybackPacketBudget.videoFrames(width: 3840, height: 2160, live: false, physicalMemory: memory) == 2, "UHD retained sixteen large frames")
            try require(PlaybackPacketBudget.videoFrames(width: 1920, height: 1080, live: false, physicalMemory: 8 * 1024 * 1024 * 1024) == 8,
                        "The ring rounded an estimated frame budget upward")
            try require(PlaybackPacketBudget.videoFrames(width: .nan, height: 2160, live: true, physicalMemory: memory) == 4, "Invalid dimensions overflowed queue capacity")
        }
        try check("media service loss blocks user resume until the reset notification") {
            var gate = PlaybackUserResumeGate<String>()
            gate.suspend(context: "episode-at-90", available: false)
            try require(gate.userResumeContext == nil && !gate.available, "Unavailable services allowed playback")
            gate.suspend(context: nil, available: true)
            try require(gate.userResumeContext == "episode-at-90", "Reset lost the playback context")
        }
        try check("duplicate reset events preserve the first context and do not consume user intent") {
            var gate = PlaybackUserResumeGate<String>()
            gate.suspend(context: "first", available: false)
            gate.suspend(context: "later-empty-core", available: true)
            try require(gate.userResumeContext == "first" && gate.context == "first", "Reset overwrote its saved selection and position")
            gate.clearPending()
            try require(gate.context == nil && gate.available, "A completed user reopen retained its old context")
        }
        try check("stopping media clears the old context while unavailable hardware remains gated") {
            var gate = PlaybackUserResumeGate<String>()
            gate.suspend(context: "old", available: false); gate.clearPending()
            try require(gate.context == nil && !gate.available, "Stop accidentally reactivated media services")
            gate.suspend(context: "new-user-selection", available: false)
            gate.suspend(context: nil, available: true)
            try require(gate.userResumeContext == "new-user-selection", "A new media selection revived the old episode")
        }
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        print("Playback resilience: all \(results.count) production checks passed")
    }
}
