import Foundation

private struct Failure: Error { let message: String }

@main enum HTTPResponseChecks {
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let limit = 4 * 1024 * 1024
        var results: [[String: Any]] = []
        func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
        func record(_ name: String) { results.append(["name": name, "passed": true]); print("PASS \(name)") }
        func load(_ path: String, timeout: TimeInterval = 5) async throws -> Data {
            try await BoundedHTTPResponse.data(for: URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout),
                configuration: .ephemeral, maximumBytes: limit)
        }
        let small = try await load("small")
        try require(String(data: small, encoding: .utf8) == "{\"fixture\":true}", "Small response changed")
        record("small configuration returns its original bytes")
        let exact = try await load("exact")
        try require(exact.count == limit && exact.first == 120 && exact.last == 120, "Exact byte limit was truncated")
        record("exact four MiB body succeeds")
        for path in ["declared", "chunked", "gzip"] {
            do {
                _ = try await load(path)
                throw Failure(message: "Oversized \(path) response succeeded")
            } catch let error as URLError where error.code == .dataLengthExceedsMaximum {}
            record("\(path) oversized body is cancelled at the receiving boundary")
        }
        let unknown = try await load("unknown")
        try require(String(data: unknown, encoding: .utf8) == "close-delimited", "Unknown-length body did not complete")
        record("close-delimited response needs no Content-Length")
        do { _ = try await load("status"); throw Failure(message: "An HTTP error was accepted") }
        catch let error as URLError where error.code == .badServerResponse {}
        record("HTTP failure is rejected before reading its body")
        let cancelled = Task { try await load("slow") }
        try await Task.sleep(for: .milliseconds(100)); cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(message: "Cancelled request returned a body") }
        catch is CancellationError {}
        catch let error as URLError where error.code == .cancelled {}
        record("explicit cancellation closes a streaming response")
        let started = ContinuousClock.now
        do { _ = try await load("slow", timeout: 0.2); throw Failure(message: "A continuously arriving response bypassed its wall deadline") }
        catch let error as URLError where error.code == .timedOut {}
        try require(started.duration(to: .now) < .seconds(4), "The resource deadline behaved like an idle timeout")
        record("streaming bytes cannot extend the wall-clock deadline")
        if CommandLine.arguments.count > 2 {
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        }
        print("Bounded HTTP responses: all \(results.count) production checks passed")
    }
}
