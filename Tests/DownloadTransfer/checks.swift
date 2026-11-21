import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckFailure(description: message) }
}

private func eventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await condition()) {
        if ContinuousClock.now >= deadline { throw CheckFailure(description: "Timed out waiting for the HTTP fixture") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor PreparedPlan {
    var latest: TransferPlan?
    func set(_ plan: TransferPlan) { latest = plan }
}

private struct RequestLog: Decodable, Sendable {
    let path: String
    let range: String?
    let acceptEncoding: String?
    let fixtureHeader: String?
    let status: Int
    let sent: Int
}

private struct Fixture: Sendable {
    let base: URL
    let root: URL
    let session: URLSession
    static let headers = ["X-Download-Fixture": "allowed"]

    func address(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }
    func folder(_ name: String) -> URL { root.appending(path: name) }

    func transfer(_ path: String, name: String, meter: DownloadMeter = DownloadMeter(),
                  resolutions: Counter? = nil, prepared: PreparedPlan? = nil,
                  headers: [String: String] = Fixture.headers) -> Transfer {
        let channel = Channel(url: address(path), headers: headers)
        return Transfer(folder: folder(name), meter: meter, session: session, resolve: {
            resolutions?.increment()
            return channel
        }, note: {
            if case let .prepared(plan) = $0 { await prepared?.set(plan) }
        })
    }

    func control(reset: Bool = false, hold: [String] = [], release: [String] = []) async throws {
        var request = URLRequest(url: address("/control"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["reset": reset, "hold": hold, "release": release])
        let (_, response) = try await session.data(for: request)
        try require((response as? HTTPURLResponse)?.statusCode == 200, "Fixture control request failed")
    }

    func requests() async throws -> [RequestLog] {
        struct Snapshot: Decodable { let requests: [RequestLog] }
        let (data, response) = try await session.data(from: address("/stats"))
        try require((response as? HTTPURLResponse)?.statusCode == 200, "Fixture stats request failed")
        return try JSONDecoder().decode(Snapshot.self, from: data).requests
    }

    func plan(_ name: String) throws -> TransferPlan {
        try JSONDecoder().decode(TransferPlan.self, from: Data(contentsOf: folder(name).appending(path: "plan.json")))
    }

    func save(_ plan: TransferPlan, name: String) throws {
        try FileManager.default.createDirectory(at: folder(name).appending(path: "parts"), withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: folder(name).appending(path: "plan.json"), options: .atomic)
    }
}

private func fileBody(_ size: Int = 4108) -> Data {
    var data = Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d])
    data.append(contentsOf: (0..<(size - data.count)).map { UInt8(truncatingIfNeeded: $0) })
    return data
}

private func partBody(_ part: TransferPlan.Part) throws -> Data {
    let leaf = part.url.lastPathComponent
    let body: Data
    switch leaf {
    case "key.key": body = Data((0..<16).map { UInt8($0) })
    case "video.bin": body = Data((0..<288).map { UInt8(($0 * 13 + 7) % 256) })
    case "audio.bin": body = Data((0..<160).map { UInt8(($0 * 17 + 3) % 256) })
    case "video-0.ts", "video-1.ts":
        let index = leaf == "video-0.ts" ? 0 : 1
        body = Data([0x47] + Array(repeating: UInt8(index + 1), count: 375))
    case "audio-0.aac", "audio-1.aac":
        body = Data(repeating: leaf == "audio-0.aac" ? 9 : 10, count: 192)
    default: throw CheckFailure(description: "Unexpected fixture asset: \(leaf)")
    }
    if let range = part.range { return Data(body[Int(range.lowerBound)...Int(range.upperBound)]) }
    return body
}

private func size(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

private func verifyWhole(_ fixture: Fixture, _ name: String, meter: DownloadMeter, size expected: Int = 4108) throws {
    let folder = fixture.folder(name)
    let saved = try fixture.plan(name)
    try require(try Data(contentsOf: folder.appending(path: "media.mp4")) == fileBody(expected),
                "\(name): final bytes differ from the complete response")
    try require(!FileManager.default.fileExists(atPath: folder.appending(path: "parts").path),
                "\(name): finished file left temporary parts behind")
    try require(saved.files.first?.length == Int64(expected), "\(name): saved length did not match delivered bytes")
    try require(meter.received == Int64(expected), "\(name): failed attempt bytes remained in progress")
    try require(meter.snapshot.expected == Int64(expected), "\(name): final expected length was stale")
}

private func verifyHLS(_ fixture: Fixture, _ name: String, externalAudio: Bool = true) throws {
    let folder = fixture.folder(name), plan = try fixture.plan(name)
    try require(plan.hlsRevision == 2, "\(name): HLS plan revision was not saved")
    for part in plan.parts {
        try require(try Data(contentsOf: folder.appending(path: part.name)) == partBody(part),
                    "\(name): incorrect asset bytes for \(part.name)")
    }
    let index = try String(contentsOf: folder.appending(path: "index.m3u8"), encoding: .utf8)
    try require(index == plan.playlist, "\(name): local master does not match the persisted plan")
    if externalAudio {
        try require(plan.playlists?.count == 2, "\(name): external audio media playlist was discarded")
        try require(index.contains("AUDIO=\"download-audio\"") && index.contains("URI=\"audio.m3u8\""),
                    "\(name): master omitted its local audio group")
        try require(index.contains("DEFAULT=YES") && !index.contains("SUBTITLES="),
                    "\(name): local master referenced unavailable media")
    } else {
        try require(plan.playlists == nil, "\(name): in-band audio unexpectedly required a companion playlist")
    }
    for (name, text) in [("index.m3u8", index)] + (plan.playlists ?? [:]).map({ ($0.key, $0.value) }) {
        try require(!text.contains("http://") && !text.contains("https://") && !text.contains("#EXT-X-BYTERANGE"),
                    "Local playlist \(name) retained remote or byte-range references")
        let source = folder.appending(path: name)
        var references = text.matches(of: /URI="([^"]+)"/).map { String($0.1) }
        references += text.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for reference in references {
            let target = URL(string: reference, relativeTo: source)!.absoluteURL
            try require(FileManager.default.fileExists(atPath: target.path), "Missing local playlist asset: \(reference)")
        }
    }
}

private func failed(_ transfer: Transfer) async throws -> Error {
    do {
        _ = try await transfer.run()
    } catch {
        return error
    }
    throw CheckFailure(description: "An incomplete or unsupported download was reported as completed")
}

@main private struct DownloadTransferChecks {
    static func main() async throws {
        try require(CommandLine.arguments.count == 4, "Expected fixture URL, download root and JSON report path")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixture = Fixture(base: URL(string: CommandLine.arguments[1])!,
                              root: URL(fileURLWithPath: CommandLine.arguments[2]), session: session)
        var results: [[String: Any]] = []
        func record(_ name: String) {
            results.append(["name": name, "passed": true])
            print("PASS \(name)")
        }
        try await fixture.control(reset: true)

        do {
            let meter = DownloadMeter()
            let result = try await fixture.transfer("/plain-retry.mp4", name: "whole-retry", meter: meter).run()
            try require(result == "media.mp4", "Whole-file retry returned the wrong playable file")
            try verifyWhole(fixture, "whole-retry", meter: meter)
            let whole = try await fixture.requests().filter { $0.path == "/plain-retry.mp4" && $0.range == nil }
            try require(whole.count == 2 && whole[0].sent == 1024 && whole[1].sent == 4108,
                        "The fixture did not exercise a 1024-byte disconnect followed by a full 4108-byte retry")
            try require(whole.allSatisfy { $0.acceptEncoding == "identity" }, "Default requests did not ask for identity encoding")
            record("non-Range retry discards its 1024-byte prefix and writes exactly 4108 bytes")
        }

        do {
            let meter = DownloadMeter()
            let plan = TransferPlan(kind: .file, headers: Fixture.headers, files: [
                .init(urls: [fixture.address("/mirror-broken.mp4"), fixture.address("/mirror-good.mp4")],
                      name: "media.part", length: 4108, ranged: false, done: [0])
            ], fileExtension: "mp4")
            try fixture.save(plan, name: "whole-mirror")
            try Data(repeating: 0xff, count: 37).write(to: fixture.folder("whole-mirror").appending(path: "parts/media.part"))
            _ = try await fixture.transfer("/mirror-good.mp4", name: "whole-mirror", meter: meter).run()
            try verifyWhole(fixture, "whole-mirror", meter: meter)
            let logs = try await fixture.requests().filter { $0.path.hasPrefix("/mirror-") }
            try require(logs.count == 2 && logs[0].sent == 1024 && logs[1].sent == 4108,
                        "Mirror fallback did not exercise a partially written first response")
            record("mirror fallback and saved non-Range plans restart from zero")
        }

        for path in ["/unknown.mp4", "/chunked.mp4", "/coded.mp4"] {
            let name = URL(string: path)!.deletingPathExtension().lastPathComponent
            let meter = DownloadMeter(), prepared = PreparedPlan()
            var headers = Fixture.headers
            if name == "coded" { headers["Accept-Encoding"] = "gzip" }
            _ = try await fixture.transfer(path, name: name, meter: meter, prepared: prepared, headers: headers).run()
            try verifyWhole(fixture, name, meter: meter)
            let initial = await prepared.latest
            try require(initial?.files.first?.length == nil && initial?.files.first?.ranged == false,
                        "\(name): unknown or decoded body length was confused with the wire length")
            if name == "coded" {
                let logs = try await fixture.requests().filter { $0.path == path }
                try require(logs.allSatisfy { $0.acceptEncoding == "gzip" && $0.sent < 4108 },
                            "The fixture did not deliver a gzip wire representation")
            }
            record("\(name) response saves the complete decoded body and its final length")
        }

        do {
            let path = "/plain-cancel.mp4", name = "whole-cancel", meter = DownloadMeter()
            try await fixture.control(hold: [path])
            let transfer = fixture.transfer(path, name: name, meter: meter)
            let task = Task { try await transfer.run() }
            defer { task.cancel() }
            try await eventually { meter.received >= 1024 }
            task.cancel()
            let result = await task.result
            try await fixture.control(release: [path])
            if case let .failure(error) = result {
                try require(error is CancellationError, "Cancelled whole-file transfer returned a non-cancellation error")
            } else { throw CheckFailure(description: "Cancelled whole-file transfer completed") }
            try require(size(fixture.folder(name).appending(path: "parts/media.part")) == 0,
                        "Cancellation left a partial whole-file prefix on disk")
            try require(try fixture.plan(name).files[0].done.isEmpty && meter.received == 0 && meter.snapshot.parts == 0,
                        "Cancellation retained completion marks or failed-attempt progress")
            try require(!FileManager.default.fileExists(atPath: fixture.folder(name).appending(path: "media.mp4").path),
                        "Cancellation published a partial playable file")
            _ = try await fixture.transfer(path, name: name, meter: meter).run()
            try verifyWhole(fixture, name, meter: meter)
            record("whole-file cancellation clears partial bytes and resumes with a full response")
        }

        do {
            let name = "ranged", meter = DownloadMeter()
            _ = try await fixture.transfer("/range.mp4", name: name, meter: meter).run()
            let count = (8 << 20) + 333
            try verifyWhole(fixture, name, meter: meter, size: count)
            try require(try fixture.plan(name).files[0].done == [0, 1, 2] && meter.snapshot.parts == 3,
                        "Ordinary ranges were not marked as complete")
            let chunks = try await fixture.requests().filter { $0.path == "/range.mp4" && $0.range != "bytes=0-65535" }
            try require(chunks.count == 3 && Set(chunks.compactMap(\.range)) == [
                "bytes=0-4194303", "bytes=4194304-8388607", "bytes=8388608-8388940"
            ], "The fixture did not exercise three distinct production-sized ranges")
            record("three ordinary HTTP ranges reconstruct the exact source bytes")
        }

        for (path, expected) in [("/range-ignore.mp4", TransferError.rangeLost), ("/range-mismatch.mp4", .incomplete)] {
            let name = URL(string: path)!.deletingPathExtension().lastPathComponent, meter = DownloadMeter()
            let error = try await failed(fixture.transfer(path, name: name, meter: meter))
            try require(error as? TransferError == expected, "\(path): invalid range response failed with the wrong error")
            try require(try fixture.plan(name).files[0].done.isEmpty && meter.received == 0,
                        "\(path): invalid ranges were committed or counted")
            try require(!FileManager.default.fileExists(atPath: fixture.folder(name).appending(path: "media.mp4").path),
                        "\(path): invalid range response published a playable file")
            record("\(name) fails explicitly without committing invalid ranges")
        }

        do {
            let meter = DownloadMeter(), name = "hls-default"
            _ = try await fixture.transfer("/hls/master.m3u8", name: name, meter: meter).run()
            try verifyHLS(fixture, name)
            let plan = try fixture.plan(name)
            try require(plan.parts.count == 7 && plan.parts.filter { $0.encryptionKey == true }.count == 1,
                        "Shared AES key or external track ranges were duplicated or omitted")
            try require(plan.playlist?.contains("NAME=\"中文, Main\"") == true, "The DEFAULT audio rendition was not selected")
            let logs = try await fixture.requests().filter { $0.path.hasPrefix("/hls/") }
            try require(logs.allSatisfy { $0.fixtureHeader == "allowed" }, "Source headers did not reach both tracks and their keys")
            try require(!logs.contains { $0.path.hasSuffix("/other.m3u8") || $0.path.hasSuffix("/low.m3u8") },
                        "The default audio or highest-bandwidth variant selection was wrong")
            try require(logs.filter { $0.path.hasSuffix("/key.key") }.count == 1 &&
                        logs.filter { $0.path.hasSuffix("/video.bin") }.count == 3 &&
                        logs.filter { $0.path.hasSuffix("/audio.bin") }.count == 3,
                        "The shared key, initialization maps or explicit/implicit byte ranges were not fetched")
            try require(meter.snapshot.parts == 7 && meter.snapshot.total == 7, "External audio was absent from completion counts")
            record("HLS default external audio writes a local master, both tracks, AES key, maps and byte ranges")
        }

        for (family, selected) in [("hls-fallback", "Alternative"), ("hls-autoselect", "Alternative")] {
            _ = try await fixture.transfer("/\(family)/master.m3u8", name: family).run()
            try verifyHLS(fixture, family)
            try require(try fixture.plan(family).playlist?.contains("NAME=\"\(selected)\"") == true,
                        "\(family): an available audio rendition was not selected")
            let logs = try await fixture.requests().filter { $0.path.hasPrefix("/\(family)/") }
            try require(logs.contains { $0.path.hasSuffix("/other.m3u8") }, "\(family): available audio was never requested")
            if family == "hls-fallback" {
                try require(logs.contains { $0.path.hasSuffix("/missing.m3u8") && $0.status == 404 },
                            "Audio fallback did not exercise an expired default rendition")
            }
            record("\(family) accepts a usable rendition from a multi-audio group")
        }

        do {
            let name = "hls-inband"
            _ = try await fixture.transfer("/\(name)/master.m3u8", name: name).run()
            try verifyHLS(fixture, name, externalAudio: false)
            let logs = try await fixture.requests().filter { $0.path.hasPrefix("/\(name)/") }
            try require(!logs.contains { $0.path.hasSuffix("/audio.m3u8") || $0.path.hasSuffix("/other.m3u8") },
                        "A legal in-band DEFAULT audio rendition was treated as an external dependency")
            record("HLS accepts a legal in-band default in a multi-audio group")
        }

        do {
            let name = "hls-resume", meter = DownloadMeter(), prepared = PreparedPlan()
            try await fixture.control(hold: ["/hls-resume/audio.bin"])
            let transfer = fixture.transfer("/hls-resume/master.m3u8", name: name, meter: meter, prepared: prepared)
            let task = Task { try await transfer.run() }
            defer { task.cancel() }
            try await eventually {
                guard let plan = await prepared.latest else { return false }
                let video = plan.parts.filter { $0.url.lastPathComponent != "audio.bin" }
                return video.allSatisfy { size(fixture.folder(name).appending(path: $0.name)) > 0 } && meter.received > 304
            }
            task.cancel()
            let result = await task.result
            try await fixture.control(release: ["/hls-resume/audio.bin"])
            if case let .failure(error) = result {
                try require(error is CancellationError, "HLS cancellation failed with the wrong error")
            } else { throw CheckFailure(description: "HLS cancellation completed with a blocked audio track") }
            let saved = try fixture.plan(name)
            try require(meter.received == 304 && meter.snapshot.parts == 4, "HLS cancellation retained in-flight audio byte counts")
            try require(!FileManager.default.fileExists(atPath: fixture.folder(name).appending(path: "index.m3u8").path),
                        "HLS cancellation published a video-only master")
            let before = try await fixture.requests().filter { $0.path == "/hls-resume/video.bin" }.count
            let key = saved.parts.first { $0.encryptionKey == true }!
            let audio = saved.parts.first { $0.url.lastPathComponent == "audio.bin" && $0.range?.lowerBound == 32 }!
            try Data(repeating: 0, count: 7).write(to: fixture.folder(name).appending(path: key.name))
            try Data(repeating: 0, count: 3).write(to: fixture.folder(name).appending(path: audio.name))
            let resolutions = Counter()
            _ = try await fixture.transfer("/hls-resume/master.m3u8", name: name, meter: meter, resolutions: resolutions).run()
            try verifyHLS(fixture, name)
            let logs = try await fixture.requests().filter { $0.path.hasPrefix("/hls-resume/") }
            try require(resolutions.value == 0, "A current saved HLS plan was unnecessarily resolved again")
            try require(logs.filter { $0.path.hasSuffix("/video.bin") }.count == before,
                        "HLS resume downloaded already completed video byte ranges again")
            try require(logs.filter { $0.path.hasSuffix("/key.key") }.count == 2,
                        "HLS resume trusted a truncated AES key")
            try require(meter.snapshot.parts == 7 && meter.received == 464, "HLS resumed progress omitted assets or counted retries twice")
            record("HLS cancellation keeps completed video and resumes missing audio, rejecting truncated keys and ranges")
        }

        do {
            let name = "hls-legacy", address = fixture.address("/hls-legacy/video.m3u8")
            let transfer = fixture.transfer("/hls-legacy/master.m3u8", name: name)
            let (data, _) = try await transfer.get([address], headers: Fixture.headers, counts: false)
            let video = try HLS.localize(String(decoding: data, as: UTF8.self), base: address)
            var parts = video.parts
            for index in parts.indices { parts[index].encryptionKey = nil }
            let old = TransferPlan(kind: .hls, headers: Fixture.headers, parts: parts, playlist: video.playlist)
            try fixture.save(old, name: name)
            for part in old.parts { try partBody(part).write(to: fixture.folder(name).appending(path: part.name)) }
            let resolutions = Counter()
            _ = try await fixture.transfer("/hls-legacy/master.m3u8", name: name, resolutions: resolutions).run()
            try verifyHLS(fixture, name)
            try require(resolutions.value == 1, "An old video-only HLS plan was not renewed")
            let logs = try await fixture.requests().filter { $0.path.hasPrefix("/hls-legacy/") }
            try require(!logs.contains { $0.path.hasSuffix(".ts") }, "Legacy plan migration discarded compatible completed video pieces")
            try require(logs.contains { $0.path.hasSuffix(".aac") }, "Legacy plan migration omitted external audio")
            record("legacy video-only plan migrates to external audio while keeping compatible video pieces")
        }

        for (family, expected) in [("hls-unsupported", TransferError.unsupportedHLS("session encryption keys")),
                                   ("hls-bad-audio", .protected), ("hls-bad-key", .incomplete)] {
            let error = try await failed(fixture.transfer("/\(family)/master.m3u8", name: family))
            try require(error as? TransferError == expected, "\(family): unsupported HLS failed with the wrong error")
            try require(!FileManager.default.fileExists(atPath: fixture.folder(family).appending(path: "index.m3u8").path),
                        "\(family): unsupported or incomplete audio published a completed local master")
            record("\(family) fails explicitly instead of completing without usable audio")
        }

        do {
            let base = fixture.address("/parser/video.m3u8")
            for playlist in [
                "#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:16\nmedia.ts\n#EXT-X-ENDLIST\n",
                "#EXTM3U\n#EXT-X-DEFINE:NAME=\"x\",VALUE=\"media.ts\"\n#EXTINF:4,\nmedia.ts\n#EXT-X-ENDLIST\n"
            ] {
                var rejected = false
                do { _ = try HLS.localize(playlist, base: base) }
                catch TransferError.unsupportedHLS { rejected = true }
                try require(rejected, "An unsupported byte-range or variable construct was silently localized")
            }
            record("unsupported implicit byte ranges and playlist variables are rejected")
        }

        let report: [String: Any] = ["kind": "production-swift-http-regression", "passed": true, "checks": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
        print("PASS \(results.count) production Swift download checks")
    }
}
