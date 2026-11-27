import Foundation

private enum CheckFailure: Error { case expected, assertion(String) }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure.assertion(message) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var cleanup = false
    private var ports: [Int] = []
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
    var cleaned: Bool { lock.withLock { cleanup } }
    func finishCleanup() { lock.withLock { cleanup = true } }
    func observe(_ port: Int) { lock.withLock { ports.append(port) } }
    var observedPorts: [Int] { lock.withLock { ports } }
}

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        let next = waiting; waiting.removeAll()
        next.forEach { $0.resume() }
    }
}

private func eventually(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        if ContinuousClock.now >= deadline { throw CheckFailure.assertion("Timed out waiting for the test admission barrier") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func cancelled<T>(_ result: Result<T, Error>) -> Bool {
    if case let .failure(error) = result { return error is CancellationError }
    return false
}

@main private struct RuntimeLifecycleChecks {
    static func main() async {
        var results: [[String: Any]] = []
        func record(_ name: String) { results.append(["name": name, "passed": true]); print("PASS \(name)") }
        let healthy = NodeHostControl(port: 8123, token: "fixture-token")
        let fallback = "runtime stopped"
        do {
            var startup = PlaybackStartupWork()
            let kinds: [PlaybackStartupWork.Kind] = [.subtitles, .remoteSkip, .danmaku]
            try require(kinds.allSatisfy { !startup.allows($0, now: 100) }, "Network work ran before a picture")
            startup.observe(ready: true, now: 100)
            startup.observe(ready: true, now: 101)
            try require(startup.allows(.subtitles, now: 101) && !startup.allows(.remoteSkip, now: 101),
                        "Automatic subtitles and remote skip started together")
            try require(startup.allows(.remoteSkip, now: 102) && !startup.allows(.danmaku, now: 102),
                        "Automatic metadata and comments started together")
            startup.observe(ready: false, now: 103)
            try require(!startup.allows(.danmaku, now: 200), "Buffering admitted automatic comments")
            startup.request(.subtitles)
            try require(startup.allows(.subtitles, now: 200) && !startup.allows(.remoteSkip, now: 200),
                        "Manual subtitles released unrelated automatic work")
            startup.observe(ready: true, now: 200)
            try require(!startup.allows(.danmaku, now: 203) && startup.allows(.danmaku, now: 204),
                        "Newly recovered picture did not get a fresh stable interval")
            startup = PlaybackStartupWork()
            try require(kinds.allSatisfy { !startup.allows($0, now: 300) }, "New episode inherited user priority")
            record("automatic subtitles, intro matching and comments yield to startup and buffering")
            do {
                let calls = Counter()
                for control in [NodeHostControl(error: "fixture-stop"), NodeHostControl(port: 0, token: "token"), NodeHostControl(port: 8123)] {
                    do {
                        try await NodeSourceCompletion.wait(control: control, fallback: fallback,
                            poll: { _ in _ = calls.next(); return true }, refresh: { $0 }, latest: { nil })
                        throw CheckFailure.assertion("An unusable host was accepted")
                    } catch NodeSourceCompletion.Failure.stopped { }
                }
                try require(calls.value == 0, "An unusable host reached its control transport")
                record("terminated or malformed control exits before polling")
            }
            do {
                let calls = Counter(), refreshes = Counter()
                try await NodeSourceCompletion.wait(control: healthy, fallback: fallback,
                    poll: { _ in calls.next() == 2 }, refresh: { control in _ = refreshes.next(); return control },
                    latest: { nil }, pause: {})
                try require(calls.value == 2 && refreshes.value == 0, "A pending acknowledgement was discarded")
                record("pending completion keeps polling until acknowledged")
            }
            do {
                let calls = Counter(), refreshes = Counter()
                try await NodeSourceCompletion.wait(control: healthy, fallback: fallback,
                    poll: { _ in if calls.next() == 1 { throw URLError(.timedOut) }; return true },
                    refresh: { control in _ = refreshes.next(); return control }, latest: { nil }, pause: {})
                try require(calls.value == 2 && refreshes.value == 0, "A transport timeout was treated as completion or termination")
                record("long-poll deadline preserves the execution fence")
            }
            do {
                let calls = Counter(), refreshes = Counter()
                let rebound = NodeHostControl(port: 9123, token: "new-token")
                try await NodeSourceCompletion.wait(control: healthy, fallback: fallback,
                    poll: { control in
                        calls.observe(control.port ?? 0)
                        if calls.next() == 1 { throw URLError(.networkConnectionLost) }
                        return true
                    }, refresh: { _ in _ = refreshes.next(); return rebound }, latest: { nil }, pause: {})
                try require(calls.observedPorts == [8123, 9123] && refreshes.value == 1, "Rebinding did not use the new control")
                record("lost transport resumes against the rebound host")
            }
            do {
                let calls = Counter(), refreshes = Counter()
                do {
                    try await NodeSourceCompletion.wait(control: healthy, fallback: fallback,
                        poll: { _ in _ = calls.next(); throw URLError(.cannotConnectToHost) },
                        refresh: { _ in _ = refreshes.next(); return NodeHostControl(error: "relisten-failed") },
                        latest: { nil }, pause: {})
                    throw CheckFailure.assertion("A terminated rebound host was retried forever")
                } catch NodeSourceCompletion.Failure.stopped { }
                try require(calls.value == 1 && refreshes.value == 1, "A terminal refresh repeated control I/O")
                record("relisten terminal state releases the old wait")
            }
            do {
                let calls = Counter(), reads = Counter()
                do {
                    try await NodeSourceCompletion.wait(control: healthy, fallback: fallback,
                        poll: { _ in _ = calls.next(); throw URLError(.timedOut) }, refresh: { $0 },
                        latest: { reads.next() == 1 ? healthy : NodeHostControl(error: "node-exited") }, pause: {})
                    throw CheckFailure.assertion("A persisted exit state was ignored")
                } catch NodeSourceCompletion.Failure.stopped { }
                try require(calls.value == 1 && reads.value == 2, "A host exit kept retrying the old port")
                record("persisted host exit ends a timed-out long poll")
            }
            do {
                let calls = Counter()
                do {
                    try await NodeSourceCompletion.wait(control: healthy, fallback: fallback,
                        poll: { _ in _ = calls.next(); throw NodeSourceCompletion.Failure.invalidReply },
                        refresh: { $0 }, latest: { nil }, pause: {})
                    throw CheckFailure.assertion("A bad control response was swallowed")
                } catch NodeSourceCompletion.Failure.invalidReply { }
                try require(calls.value == 1, "A malformed acknowledgement looped")
                record("protocol failures are not swallowed as deadlines")
            }
            do {
                let calls = Counter()
                let waiter = Task {
                    try await NodeSourceCompletion.wait(control: healthy, fallback: fallback,
                        poll: { _ in _ = calls.next(); return false }, refresh: { $0 }, latest: { nil })
                }
                try await eventually { calls.value == 1 }
                waiter.cancel()
                try require(cancelled(await waiter.result), "Cancelling a completion waiter did not end its retry delay")
                record("explicit cancellation terminates the retry delay")
            }
            do {
                let registry = RuntimeStartupRegistry<Int>(), gate = Gate(), starts = Counter()
                let factory: @Sendable () async throws -> Int = { _ = starts.next(); await gate.wait(); try Task.checkCancellation(); return 42 }
                let first = Task { try await registry.value(for: "same", operation: factory) }
                let second = Task { try await registry.value(for: "same", operation: factory) }
                try await eventually { await registry.waiterCount(for: "same") == 2 }
                try require(starts.value == 1, "Same-key startup created two initializers")
                await gate.open()
                let a = try await first.value, b = try await second.value
                try require(a == 42 && b == 42 && starts.value == 1, "Joined callers did not share the startup result")
                record("concurrent same-key callers start one runtime")
            }
            do {
                let registry = RuntimeStartupRegistry<Int>(), gate = Gate(), starts = Counter()
                let factory: @Sendable () async throws -> Int = { _ = starts.next(); await gate.wait(); try Task.checkCancellation(); return 7 }
                let first = Task { try await registry.value(for: "shared", operation: factory) }
                let second = Task { try await registry.value(for: "shared", operation: factory) }
                try await eventually { await registry.waiterCount(for: "shared") == 2 }
                first.cancel()
                try await eventually { await registry.waiterCount(for: "shared") == 1 }
                await gate.open()
                let firstResult = await first.result, secondValue = try await second.value
                try require(cancelled(firstResult) && secondValue == 7 && starts.value == 1, "One caller cancelled another caller's initializer")
                record("one cancelled caller preserves the other startup lease")
            }
            do {
                let registry = RuntimeStartupRegistry<Int>(), gate = Gate(), starts = Counter()
                let factory: @Sendable () async throws -> Int = {
                    _ = starts.next(); await gate.wait()
                    do { try Task.checkCancellation() } catch { starts.finishCleanup(); throw error }
                    return 1
                }
                let first = Task { try await registry.value(for: "replace", operation: factory) }
                let second = Task { try await registry.value(for: "replace", operation: factory) }
                try await eventually { await registry.waiterCount(for: "replace") == 2 }
                first.cancel(); second.cancel()
                try await eventually { await registry.waiterCount(for: "replace") == 0 }
                let replacement = Task {
                    try await registry.value(for: "replace") {
                        try require(starts.cleaned, "Replacement started before the abandoned initializer cleaned up")
                        _ = starts.next(); return 9
                    }
                }
                await gate.open()
                let oldA = await first.result, oldB = await second.result, newValue = try await replacement.value
                try require(cancelled(oldA) && cancelled(oldB) && newValue == 9 && starts.value == 2, "Abandoned startup was reused or leaked")
                record("last cancellation drains startup before replacement")
            }
            do {
                let registry = RuntimeStartupRegistry<Int>(), gate = Gate(), starts = Counter()
                let factory: @Sendable () async throws -> Int = { _ = starts.next(); await gate.wait(); throw CheckFailure.expected }
                let first = Task { try await registry.value(for: "failure", operation: factory) }
                let second = Task { try await registry.value(for: "failure", operation: factory) }
                try await eventually { await registry.waiterCount(for: "failure") == 2 }
                await gate.open()
                let oldA = await first.result, oldB = await second.result
                if case .success = oldA { throw CheckFailure.assertion("Failed initializer returned a value") }
                if case .success = oldB { throw CheckFailure.assertion("Joined failure was lost") }
                let fresh = try await registry.value(for: "failure") { _ = starts.next(); return 21 }
                try require(fresh == 21 && starts.value == 2, "An initialization error poisoned future requests")
                record("joined startup failure allows a fresh initializer")
            }
            do {
                let registry = RuntimeStartupRegistry<Int>(), gate = Gate(), starts = Counter()
                let a = Task { try await registry.value(for: "a") { _ = starts.next(); await gate.wait(); return 1 } }
                let b = Task { try await registry.value(for: "b") { _ = starts.next(); await gate.wait(); return 2 } }
                try await eventually { starts.value == 2 }
                await gate.open()
                let aValue = try await a.value, bValue = try await b.value
                try require(aValue == 1 && bValue == 2, "Different sources blocked each other's startup")
                record("different source keys initialize independently")
            }
            do {
                let registry = RuntimeStartupRegistry<Int>(), gate = Gate(), starts = Counter()
                let caller = Task { await gate.wait(); return try await registry.value(for: "cancelled") { _ = starts.next(); return 1 } }
                caller.cancel(); await gate.open()
                try require(cancelled(await caller.result) && starts.value == 0, "A pre-cancelled caller opened a runtime")
                record("pre-cancelled callers never enter startup")
            }
            if CommandLine.arguments.count > 1 {
                let data = try JSONSerialization.data(withJSONObject: ["cases": results, "passed": results.count], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
            }
            print("Runtime lifecycle checks passed: \(results.count)")
        } catch {
            FileHandle.standardError.write(Data("Runtime lifecycle check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
