import Foundation
import Darwin

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckFailure(description: message) }
}
private struct ResultRow: Codable { let name: String; let passed: Bool; let failure: String? }
@MainActor private final class ImportResult { var value: Result<LocalMediaBadgeStore, Error>? }

private final class FixtureReplies: @unchecked Sendable {
    static let shared = FixtureReplies()
    private let lock = NSLock()
    private var requests: [FixtureProtocol] = []
    func reset() { lock.withLock { requests = [] } }
    func add(_ request: FixtureProtocol) { lock.withLock { requests.append(request) } }
    var count: Int { lock.withLock { requests.count } }
    func reply(_ index: Int, data: Data) {
        let request = lock.withLock { requests[index] }
        request.reply(data)
    }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { FixtureReplies.shared.add(self) }
    override func stopLoading() { lock.withLock { stopped = true } }
    func reply(_ data: Data) {
        guard !lock.withLock({ stopped }) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
private func fixtureSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]; config.urlCache = nil
    return URLSession(configuration: config)
}
private func scheme(_ name: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["name": name, "filters": [[
        "id": "fixture", "name": name, "pattern": ".*", "groupId": "fixture",
        "imageURL": "https://images.fixture.invalid/badge.png", "isEnabled": true,
    ]]])
}
@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CheckFailure(description: "The controlled request did not complete")
}

@main enum SettingsLifecycleChecks {
    @MainActor static func main() async {
        var rows: [ResultRow] = []
        let suite = "yingxia.settings-lifecycle." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        @MainActor func run(_ name: String, _ operation: @MainActor () async throws -> Void) async {
            defaults.removePersistentDomain(forName: suite)
            do { try await operation(); rows.append(ResultRow(name: name, passed: true, failure: nil)) }
            catch { rows.append(ResultRow(name: name, passed: false, failure: String(describing: error))) }
        }

        await run("restored danmaku preferences synchronously refresh every cached field") {
            defaults.set(true, forKey: "danmakuEnabled"); defaults.set(true, forKey: "danmakuAutoMatch")
            defaults.set(0.9, forKey: "danmakuOpacity"); defaults.set(30.0, forKey: "danmakuFontSize")
            let model = CatalogDanmakuModel(defaults: defaults)
            var updates = 0
            model.nativeAutomatic = { updates += 1 }
            defaults.set(false, forKey: "danmakuEnabled"); defaults.set(false, forKey: "danmakuAutoMatch")
            defaults.set(0.35, forKey: "danmakuOpacity"); defaults.set(44.0, forKey: "danmakuFontSize")
            LocalDanmakuPreferences.restored()
            try expect(!model.enabled && !model.automatic, "Restored switches must reach the existing session")
            try expect(model.opacity == 0.35 && model.fontSize == 44, "Restored appearance must reach the existing session")
            try expect(updates == 1, "Only one native refresh may observe a complete snapshot")
            defaults.removePersistentDomain(forName: suite)
            LocalDanmakuPreferences.restored()
            try expect(model.enabled && model.automatic && model.opacity == 0.9 && model.fontSize == 30, "Replacement without keys must restore defaults")
            try expect(defaults.object(forKey: "danmakuEnabled") == nil, "Reload must not persist defaults over the restored snapshot")
        }
        await run("direct player edits still persist to the same preference store") {
            let model = CatalogDanmakuModel(defaults: defaults)
            model.enabled = false; model.automatic = false; model.opacity = 0.6; model.fontSize = 22
            let saved = LocalDanmakuPreferences.load(defaults: defaults)
            try expect(!saved.enabled && !saved.automatic && saved.opacity == 0.6 && saved.fontSize == 22, "Player edits must persist all fields")
        }
        await run("invalid restored appearance values are normalized") {
            defaults.set(-1.0, forKey: "danmakuOpacity"); defaults.set(500.0, forKey: "danmakuFontSize")
            let saved = LocalDanmakuPreferences.load(defaults: defaults)
            try expect(saved.opacity == 0 && saved.fontSize == 64, "Restored values must stay in the supported ranges")
        }
        await run("API key selection cannot test a hidden token") {
            let draft = TMDBServiceSettings(apiBase: "https://api.fixture.invalid/3", token: "hidden-token", enabled: true)
            let current = draft.formConfiguration(credentialType: .apiKey)
            let request = try current.request(path: "configuration", parameters: [:])
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "The hidden token must not authenticate a test")
            try current.save(defaults: defaults)
            try expect(TMDBServiceSettings.load(defaults: defaults) == current, "Save and test must use the same normalized configuration")
            try expect(draft.token == "hidden-token", "Normalizing must preserve inactive draft fields until save")
        }
        await run("token selection cannot test a hidden API key") {
            let draft = TMDBServiceSettings(apiBase: "https://api.fixture.invalid/3", apiKey: "hidden-key", enabled: true)
            let current = draft.formConfiguration(credentialType: .token)
            let request = try current.request(path: "configuration", parameters: [:])
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            try expect(!query.contains(where: { $0.name == "api_key" }), "The hidden key must not authenticate a test")
            try current.save(defaults: defaults)
            try expect(TMDBServiceSettings.load(defaults: defaults) == current, "Saved credentials must match the tested configuration")
        }
        await run("TMDB form normalization preserves proxy and language settings") {
            let draft = TMDBServiceSettings(apiBase: " https://api.themoviedb.org/ ", apiKey: "visible-key", token: "hidden-token",
                language: " en-US ", enabled: true, ultraHD: true, proxyEnabled: true, proxyUrl: " http://proxy.fixture.invalid:8080 ",
                proxyUsername: "fixture", proxyPassword: "password")
            let current = draft.formConfiguration(credentialType: .apiKey)
            try current.save(defaults: defaults)
            try expect(current.token.isEmpty && current.apiKey == "visible-key" && current.language == "en-US", "Normalize only the active credential and canonical fields")
            try expect(current.ultraHD && current.proxyPassword == "password", "Other settings must remain intact")
            let tested = try current.request(path: "configuration", parameters: [:])
            let saved = try TMDBServiceSettings.load(defaults: defaults).request(path: "configuration", parameters: [:])
            try expect(tested == saved, "Test and saved requests must be identical")
        }
        await run("late badge import preserves newer selection and deleted schemes") {
            FixtureReplies.shared.reset()
            let session = fixtureSession(); defer { session.invalidateAndCancel() }
            var store = LocalMediaBadgeStore()
            try store.add(address: "https://badges.fixture.invalid/a", data: scheme("A"))
            try store.add(address: "https://badges.fixture.invalid/b", data: scheme("B"))
            let a = store.sources.first { $0.name == "A" }!.id, b = store.sources.first { $0.name == "B" }!.id
            store.apply(a); try store.save(defaults: defaults)
            let importer = LocalMediaBadgeImporter(defaults: defaults, session: session), result = ImportResult()
            try importer.start(address: "https://badges.fixture.invalid/c") { result.value = $0 }
            try await waitUntil { FixtureReplies.shared.count == 1 }
            var newer = LocalMediaBadgeStore.load(defaults: defaults)
            newer.apply(b); newer.remove(a); try newer.save(defaults: defaults)
            FixtureReplies.shared.reply(0, data: try scheme("C"))
            try await waitUntil { result.value != nil }
            guard case .success? = result.value else { throw CheckFailure(description: "The new scheme failed to import") }
            let saved = LocalMediaBadgeStore.load(defaults: defaults)
            try expect(saved.activeID == b && !saved.sources.contains(where: { $0.id == a }), "Late import must preserve the newer selection and deletion")
            try expect(saved.sources.contains(where: { $0.name == "C" }), "The new scheme must merge into the latest store")
        }
        await run("deleted refresh target cannot be resurrected by its old request") {
            FixtureReplies.shared.reset()
            let session = fixtureSession(); defer { session.invalidateAndCancel() }
            let address = "https://badges.fixture.invalid/a"
            var store = LocalMediaBadgeStore(); try store.add(address: address, data: scheme("A")); try store.save(defaults: defaults)
            let id = store.sources.first { $0.address == address }!.id
            let importer = LocalMediaBadgeImporter(defaults: defaults, session: session), result = ImportResult()
            try importer.start(address: address) { result.value = $0 }
            try await waitUntil { FixtureReplies.shared.count == 1 }
            var newer = LocalMediaBadgeStore.load(defaults: defaults); newer.remove(id); try newer.save(defaults: defaults)
            FixtureReplies.shared.reply(0, data: try scheme("Old refresh"))
            try await waitUntil { result.value != nil }
            guard case .failure(let error)? = result.value, let failure = error as? LocalMediaBadgeStore.BadgeError,
                  case .changed = failure else { throw CheckFailure(description: "The obsolete target must be rejected") }
            try expect(!LocalMediaBadgeStore.load(defaults: defaults).sources.contains(where: { $0.id == id }), "Deleted scheme must stay deleted")
        }
        await run("cancelled import cannot commit or complete after a newer request") {
            FixtureReplies.shared.reset()
            let session = fixtureSession(); defer { session.invalidateAndCancel() }
            let importer = LocalMediaBadgeImporter(defaults: defaults, session: session)
            let old = ImportResult(), current = ImportResult()
            try importer.start(address: "https://badges.fixture.invalid/old") { old.value = $0 }
            try await waitUntil { FixtureReplies.shared.count == 1 }
            importer.cancel()
            try importer.start(address: "https://badges.fixture.invalid/new") { current.value = $0 }
            try await waitUntil { FixtureReplies.shared.count == 2 }
            FixtureReplies.shared.reply(0, data: try scheme("Old")); FixtureReplies.shared.reply(1, data: try scheme("New"))
            try await waitUntil { current.value != nil }
            try expect(old.value == nil, "Cancelled owner must not receive a late completion")
            let saved = LocalMediaBadgeStore.load(defaults: defaults)
            try expect(saved.sources.contains(where: { $0.name == "New" }) && !saved.sources.contains(where: { $0.name == "Old" }), "Only the newer import may persist")
        }

        if CommandLine.arguments.count > 1 {
            do { try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
            catch { print("Could not write check results: \(error)"); exit(1) }
        }
        for row in rows { print("\(row.passed ? "PASS" : "FAIL") \(row.name)\(row.failure.map { ": " + $0 } ?? "")") }
        if rows.contains(where: { !$0.passed }) { exit(1) }
    }
}
