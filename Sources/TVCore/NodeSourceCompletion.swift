import Foundation

struct NodeHostControl: Codable, Sendable {
    var port: Int?
    var token: String?
    var error: String?

    var usable: Bool {
        error == nil && port.map { (1...65535).contains($0) } == true && token?.isEmpty == false
    }

    func requireUsable(fallback: String) throws {
        guard usable else { throw NodeSourceCompletion.Failure.stopped(error ?? fallback) }
    }
}

/// Retry transport deadlines while the host is alive. A terminated host cannot
/// acknowledge an old source operation and must not retain its admission forever.
enum NodeSourceCompletion {
    enum Failure: LocalizedError, Sendable {
        case stopped(String), invalidReply
        var errorDescription: String? {
            switch self {
            case let .stopped(reason): reason
            case .invalidReply: "The CatPawOpen runtime returned an invalid completion response."
            }
        }
    }

    static func wait(control: NodeHostControl, fallback: String,
        poll: @Sendable (NodeHostControl) async throws -> Bool,
        refresh: @Sendable (NodeHostControl) async throws -> NodeHostControl,
        latest: @Sendable () async -> NodeHostControl?,
        pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) async throws {
        var current = control
        while true {
            try Task.checkCancellation()
            if let state = await latest() { current = state }
            try current.requireUsable(fallback: fallback)
            do {
                if try await poll(current) { return }
            } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost].contains(error.code) {
                current = try await refresh(current)
                try current.requireUsable(fallback: fallback)
            } catch let error as URLError where error.code == .timedOut {
                // A long-poll deadline is not an execution-completion acknowledgement.
            } catch { throw error }
            try await pause()
        }
    }
}
