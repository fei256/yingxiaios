import Foundation

/// A cancelled caller leaves shared startup running while another caller still needs it.
/// The last cancellation stops the initializer; replacement waits for its cleanup fence.
actor RuntimeStartupRegistry<Value: Sendable> {
    private var pending: [String: Startup] = [:]

    func value(for key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        while let previous = pending[key], previous.isCancelled {
            _ = await previous.result
            if pending[key] === previous { pending[key] = nil }
            try Task.checkCancellation()
        }
        if let current = pending[key] { return try await current.value() }
        let current = Startup(operation: operation)
        pending[key] = current
        defer { if pending[key] === current { pending[key] = nil } }
        return try await current.value()
    }

    /// A lock-protected admission snapshot, also useful for deterministic concurrency checks.
    func waiterCount(for key: String) -> Int { pending[key]?.waiterCount ?? 0 }

    private final class Startup: @unchecked Sendable {
        private let lock = NSLock()
        private let task: Task<Value, Error>
        private var waiters: Set<UUID> = []
        private var abandoned = false

        init(operation: @escaping @Sendable () async throws -> Value) {
            task = Task.detached(priority: .userInitiated, operation: operation)
        }

        var isCancelled: Bool { lock.withLock { abandoned || task.isCancelled } }
        var result: Result<Value, Error> { get async { await task.result } }
        var waiterCount: Int { lock.withLock { waiters.count } }

        func value() async throws -> Value {
            let waiter = UUID()
            let admitted = lock.withLock {
                guard !abandoned, !task.isCancelled else { return false }
                waiters.insert(waiter)
                return true
            }
            if !admitted { _ = await task.result; throw CancellationError() }
            defer { lock.withLock { _ = waiters.remove(waiter) } }
            return try await withTaskCancellationHandler {
                let answer = try await task.value
                try Task.checkCancellation()
                return answer
            } onCancel: { self.cancel(waiter) }
        }

        private func cancel(_ waiter: UUID) {
            let stop = lock.withLock {
                guard waiters.remove(waiter) != nil else { return false }
                if waiters.isEmpty { abandoned = true; return true }
                return false
            }
            if stop { task.cancel() }
        }
    }
}
