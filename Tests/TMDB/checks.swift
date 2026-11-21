import Foundation
import Darwin

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckFailure(description: message) }
}

private struct Reply: Sendable {
    var status = 200
    var data: Data
    var headers: [String: String] = ["Content-Type": "application/json"]
    var error: URLError.Code?
    init(_ json: String, status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"]) {
        data = Data(json.utf8); self.status = status; self.headers = headers
    }
}

private final class FixtureServer: @unchecked Sendable {
    static let shared = FixtureServer()
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var handler: @Sendable (URLRequest, Int) -> Reply = { request, _ in standardReply(request) }
    func reset(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply = { request, _ in standardReply(request) }) {
        lock.withLock { requests = []; self.handler = handler }
    }
    func respond(_ request: URLRequest) -> Reply {
        let (callback, count) = lock.withLock { requests.append(request); return (handler, requests.count) }
        return callback(request, count)
    }
    var calls: [URLRequest] { lock.withLock { requests } }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = FixtureServer.shared.respond(request)
        if let code = reply.error { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private let aggregate = #"{"cast":[{"id":1,"name":"测试演员甲","profile_path":"/actor.jpg","roles":[{"character":"Han Li (voice)","episode_count":200}]},{"id":2,"name":"测试演员乙","profile_path":null,"roles":[{"character":"Han Yun Zhi (voice)","episode_count":40}]}],"crew":[{"id":3,"name":"测试导演","profile_path":"/director.jpg","jobs":[{"job":"Director","episode_count":200}]}]}"#
private let show = #"{"id":107371,"name":"凡人修仙传","original_name":"A Record of a Mortal's Journey to Immortality","first_air_date":"2020-07-25","overview":"测试简介","original_language":"zh","vote_average":8.6,"vote_count":300,"poster_path":"/poster.jpg","backdrop_path":"/captioned.jpg","number_of_episodes":200,"episode_run_time":[20],"origin_country":["CN"],"genres":[{"id":16,"name":"动画"}],"seasons":[{"season_number":1,"name":"第一季","episode_count":200,"air_date":"2020-07-25","poster_path":"/season.jpg"}],"credits":{"cast":[{"id":2,"name":"测试演员乙","profile_path":"/actor2.jpg","character":"Han Yun Zhi (voice)"}]},"images":{"logos":[{"file_path":"/english.png","iso_639_1":"en","vote_count":100},{"file_path":"/chinese.png","iso_639_1":"zh","vote_count":20}],"backdrops":[{"file_path":"/captioned.jpg","iso_639_1":"zh","aspect_ratio":1.78,"vote_count":100},{"file_path":"/textless.jpg","iso_639_1":null,"aspect_ratio":1.78,"vote_count":10}],"posters":[{"file_path":"/textless-poster.jpg","iso_639_1":null,"aspect_ratio":0.67,"vote_count":10}]},"external_ids":{"imdb_id":"tt12345678"},"next_episode_to_air":{"season_number":1,"episode_number":201,"air_date":"2026-11-28"},"recommendations":{"results":[]},"production_companies":[],"networks":[]}"#
private let seasonJSON = #"{"season_number":1,"name":"第一季","overview":"测试季简介","air_date":"2020-07-25","poster_path":"/season.jpg","episodes":[{"episode_number":4,"name":"测试第四集","overview":"第四集简介","still_path":"/episode4.jpg","air_date":"2020-08-01","runtime":18,"vote_average":8.2},{"episode_number":200,"name":"测试第二百集","overview":"第二百集简介","still_path":"/episode200.jpg","air_date":"2026-11-14","runtime":20,"vote_average":8.5}]}"#
private let searchJSON = #"{"page":1,"total_pages":1,"results":[{"id":107371,"media_type":"tv","name":"凡人修仙传","original_name":"A Record of a Mortal's Journey to Immortality","first_air_date":"2020-07-25","poster_path":"/poster.jpg","vote_average":8.6}]}"#
private let imageBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jM1cAAAAASUVORK5CYII=")!

private func showReply(aggregateIncluded: Bool = true) -> Reply {
    var object = try! JSONSerialization.jsonObject(with: Data(show.utf8)) as! [String: Any]
    if aggregateIncluded { object["aggregate_credits"] = try! JSONSerialization.jsonObject(with: Data(aggregate.utf8)) }
    var reply = Reply("{}"); reply.data = try! JSONSerialization.data(withJSONObject: object); return reply
}
private func standardReply(_ request: URLRequest) -> Reply {
    let path = request.url!.path
    if path.hasPrefix("/t/p/") { var reply = Reply("{}"); reply.data = imageBytes; reply.headers = ["Content-Type": "image/png"]; return reply }
    switch path {
    case "/3/configuration": return Reply(#"{"images":{"secure_base_url":"https://images.fixture/t/p/","poster_sizes":["w500","original"]}}"#)
    case "/3/search/multi", "/3/search/tv": return Reply(searchJSON)
    case "/3/tv/107371": return showReply()
    case "/3/tv/107371/aggregate_credits": return Reply(aggregate)
    case "/3/tv/107371/season/1": return Reply(seasonJSON)
    case "/3/person/1": return Reply(#"{"id":1,"name":"测试演员甲","profile_path":"/actor.jpg","biography":"测试人物简介","known_for_department":"Acting","external_ids":{"instagram_id":"fixture"},"combined_credits":{"cast":[{"id":107371,"media_type":"tv","name":"凡人修仙传","first_air_date":"2020-07-25","character":"Han Li (voice)"}],"crew":[]}}"#)
    case "/3/search/keyword": return Reply(#"{"page":1,"total_pages":2,"results":[{"id":10,"name":"修仙"}]}"#)
    case "/3/person/popular", "/3/search/person": return Reply(#"{"page":2,"total_pages":3,"results":[{"id":1,"name":"测试演员甲","profile_path":"/actor.jpg","known_for_department":"Acting","known_for":[]}]}"#)
    default: return Reply(#"{"success":false,"status_code":34}"#, status: 404)
    }
}

private func configuration() -> TMDBServiceSettings {
    TMDBServiceSettings(apiBase: "https://api.fixture/3", apiKey: "fixture-key", imageBase: "https://images.fixture/t/p", language: "zh-CN", enabled: true)
}
private func fixtureSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]; config.urlCache = nil
    return URLSession(configuration: config)
}
private func errorFrom(_ operation: () async throws -> Void) async throws -> Error {
    do { try await operation() }
    catch { return error }
    throw CheckFailure(description: "The operation unexpectedly succeeded")
}
private struct ResultRow: Codable { let name: String; let passed: Bool; let failure: String? }

@main enum TMDBChecks {
    static func main() async {
        let results = await runChecks()
        let failed = results.filter { !$0.passed }
        if CommandLine.arguments.count > 1 {
            try? JSONEncoder().encode(results).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("TMDB adapter checks: \(results.count - failed.count)/\(results.count) passed.")
        if !failed.isEmpty { exit(1) }
    }
    private static func runChecks() async -> [ResultRow] {
        let session = fixtureSession(), config = configuration()
        defer { session.invalidateAndCancel() }
        var results: [ResultRow] = []
        func run(_ name: String, _ check: () async throws -> Void) async {
            FixtureServer.shared.reset()
            do { try await check(); results.append(ResultRow(name: name, passed: true, failure: nil)); print("PASS \(name)") }
            catch { results.append(ResultRow(name: name, passed: false, failure: String(describing: error))); print("FAIL \(name): \(error)") }
        }
        await run("v3 key request preserves the API path") {
            let request = try config.request(path: "tv/107371", parameters: [:])
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            try expect(request.url!.path == "/3/tv/107371", "Wrong API path")
            try expect(query.first { $0.name == "api_key" }?.value == "fixture-key", "Missing v3 authentication")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "v3 must not add Bearer authentication")
        }
        await run("pasted Bearer token has exactly one prefix") {
            var value = config; value.token = "  Bearer fixture-token  "
            let request = try value.request(path: "configuration", parameters: [:])
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Doubled Bearer prefix")
            try expect(!request.url!.absoluteString.contains("api_key"), "Bearer must not leak a v3 key into the URL")
        }
        await run("JWT pasted into the key field selects token authentication") {
            var value = config; value.apiKey = "fixture.payload.signature"
            let request = try value.request(path: "configuration", parameters: [:])
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture.payload.signature", "JWT was treated as a v3 key")
        }
        await run("official hostname without version normalizes to v3") {
            var value = config; value.apiBase = "https://api.themoviedb.org/"
            try expect(try value.request(path: "configuration", parameters: [:]).url?.path == "/3/configuration", "The version path must be added")
        }
        await run("language defaults and explicit overrides agree") {
            var value = config; value.language = "ja-JP"
            let inherited = try value.request(path: "configuration", parameters: [:]).url!.absoluteString
            let explicit = try value.request(path: "configuration", parameters: ["language":"en-US"]).url!.absoluteString
            try expect(inherited.contains("language=ja-JP") && explicit.contains("language=en-US"), "Explicit language was overwritten")
        }
        await run("turning custom TMDB off retains saved configuration") {
            let name = "yingxia-tmdb-check-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            try config.save(defaults: defaults)
            var value = TMDBServiceSettings.load(defaults: defaults); value.enabled = false; try value.save(defaults: defaults)
            let restored = TMDBServiceSettings.load(defaults: defaults)
            try expect(restored.custom == nil && restored.apiKey == config.apiKey && restored.serviceIdentity == "builtin", "Custom configuration was discarded")
            TMDBServiceSettings.clear(defaults: defaults)
            try expect(!TMDBServiceSettings.load(defaults: defaults).enabled, "Clear did not restore the default service")
        }
        await run("proxy changes and image quality preserve title choices") {
            var value = config; value.proxyEnabled = true; value.proxyUrl = "socks5://127.0.0.1:7890"; value.ultraHD = true
            try expect(value.serviceIdentity == config.serviceIdentity, "Transport settings invalidated manual matching")
            try expect(try value.proxyConfiguration()?["url"] == "socks5://127.0.0.1:7890", "SOCKS5 configuration failed")
        }
        await run("invalid proxy schemes and incomplete authentication fail validation") {
            var value = config; value.proxyEnabled = true; value.proxyUrl = "ftp://127.0.0.1:7890"
            do { _ = try value.proxyConfiguration(); throw CheckFailure(description: "FTP proxy was accepted") } catch is URLError {}
            value.proxyUrl = "http://127.0.0.1:7890"; value.proxyPassword = "fixture-password"
            do { _ = try value.proxyConfiguration(); throw CheckFailure(description: "Password without username was accepted") } catch is URLError {}
        }
        await run("custom images and ultra HD preserve resource identity") {
            let address = config.image("/actor.jpg", size: "w185")!
            try expect(address.absoluteString == "https://images.fixture/t/p/w185/actor.jpg", "Wrong image mirror path")
            var value = config; value.ultraHD = true
            try expect(TMDBServiceSettings.artworkURL(address, settings: value).path == "/t/p/original/actor.jpg", "HD image size was not applied")
            let other = URL(string: "https://source.fixture/w500/cover.jpg")!
            try expect(TMDBServiceSettings.artworkURL(other, settings: value) == other, "Source artwork was rewritten")
        }
        await run("HTTP 401 gives an actionable credential error") {
            FixtureServer.shared.reset { _, _ in Reply("{}", status: 401) }
            let error = try await errorFrom { _ = try await CustomTMDBService.object("configuration", config: config, session: session) }
            try expect(error as? TMDBConnectionError == .http(401), "Authentication failure was hidden")
            try expect(!TMDBConnectionError.message(for: error).contains(config.apiKey), "Diagnostic exposed a credential")
        }
        await run("invalid JSON and application error payloads are rejected") {
            FixtureServer.shared.reset { _, _ in Reply("<html>gateway</html>") }
            let invalid = try await errorFrom { _ = try await CustomTMDBService.object("configuration", config: config, session: session) }
            try expect(invalid as? TMDBConnectionError == .invalidResponse, "HTML was accepted as TMDB metadata")
            FixtureServer.shared.reset { _, _ in Reply(#"{"success":false,"status_code":7}"#) }
            let rejected = try await errorFrom { _ = try await CustomTMDBService.object("configuration", config: config, session: session) }
            try expect(rejected as? TMDBConnectionError == .http(401), "Application-level authentication failure was accepted")
        }
        await run("rate limits retry once with a bounded delay") {
            FixtureServer.shared.reset { request, count in count == 1 ? Reply("{}", status: 429, headers: ["Retry-After":"0"]) : standardReply(request) }
            _ = try await CustomTMDBService.object("configuration", config: config, session: session)
            try expect(FixtureServer.shared.calls.count == 2, "429 recovery did not retry exactly once")
            FixtureServer.shared.reset { _, _ in Reply("{}", status: 429, headers: ["Retry-After":"0"]) }
            let failure = try await errorFrom { _ = try await CustomTMDBService.object("configuration", config: config, session: session) }
            try expect(failure as? TMDBConnectionError == .http(429) && FixtureServer.shared.calls.count == 2, "Retry budget was exceeded")
        }
        await run("series loads aggregate cast, roles and available fallback portraits") {
            let details = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session)
            try expect(details.cast.count == 2 && details.cast[0].role == "Han Li (voice)", "Whole-series cast or aggregate role missing")
            try expect(details.cast[1].profile?.path == "/t/p/w185/actor2.jpg", "A duplicate latest credit lost its useful portrait")
            try expect(details.crew.first?.role == "Director", "Aggregate crew role missing")
            let query = FixtureServer.shared.calls.first!.url!.absoluteString
            try expect(query.contains("aggregate_credits") && query.contains("translations"), "Direct metadata did not request the complete enrichment")
        }
        await run("localized logo and textless backdrop are selected separately") {
            let details = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session)
            try expect(details.logo?.lastPathComponent == "chinese.png", "The localized wordmark was ignored")
            try expect(details.backdrop?.lastPathComponent == "textless.jpg", "A captioned backdrop duplicated the foreground title")
        }
        await run("missing appended aggregate credits use the standalone endpoint") {
            FixtureServer.shared.reset { request, _ in request.url!.path == "/3/tv/107371" ? showReply(aggregateIncluded: false) : standardReply(request) }
            let details = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session)
            try expect(details.cast.count == 2, "Standalone aggregate fallback failed")
            try expect(FixtureServer.shared.calls.contains { $0.url!.path.hasSuffix("aggregate_credits") }, "No fallback request was made")
        }
        await run("a failed season keeps the work and cast") {
            FixtureServer.shared.reset { request, _ in request.url!.path.contains("/season/") ? Reply("{}", status: 404) : standardReply(request) }
            let details = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session)
            try expect(details.id == 107371 && details.cast.count == 2 && details.poster != nil, "A season failure discarded successful work metadata")
            try expect(details.season == nil && details.metadataWarnings?.isEmpty == false, "Missing season was silently treated as complete")
        }
        await run("a response for the wrong season never maps source episodes") {
            FixtureServer.shared.reset { request, _ in request.url!.path.contains("/season/") ? Reply(#"{"season_number":9,"episodes":[]}"#) : standardReply(request) }
            let details = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session)
            try expect(details.season == nil && !details.cast.isEmpty, "Wrong-season metadata was adopted")
        }
        await run("cancelled season requests propagate cancellation") {
            FixtureServer.shared.reset { request, _ in
                var reply = standardReply(request)
                if request.url!.path.contains("/season/") { reply.error = .cancelled }
                return reply
            }
            let failure = try await errorFrom { _ = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session) }
            try expect(failure is CancellationError, "Cancelled work continued as partial metadata")
        }
        await run("episode variants share metadata while extras and other seasons do not") {
            let details = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session)
            let names = ["A.Record.of.a.Mortals.Journey.to.Immortality.S01E04.2020.2160p.WEB-DL.H265.HDR.AAC [574MB]", "S01E04 SDR", "S01E200", "S02E04", "S01E01-E04", "预告片"]
            let episodes = details.episodes(for: names, numbering: .season)
            try expect(episodes[0]?.number == 4 && episodes[1]?.number == 4 && episodes[2]?.number == 200, "Numbered variants were not aligned")
            try expect(episodes.suffix(3).allSatisfy { $0 == nil }, "An extra, pack or other season borrowed a still")
        }
        await run("release filename normalization removes size, episode and year") {
            let filename = "[1.5GB]A.Record.of.a.Mortals.Journey.to.Immortality.S01E04.2020.2160p.WEB-DL.H265.HDR.AAC.mp4"
            try expect(TMDBTitleMatching.query(filename) == "A Record of a Mortals Journey to Immortality", "Release metadata polluted the search query")
            try expect(TMDBTitleMatching.sourceYear(nil, title: "凡人修仙传", episodes: [filename]) == "2020", "Post-episode release year was missed")
        }
        await run("aliases deduplicate queries and resolve one work") {
            let request = TMDBMatch.Request(video: Video("凡人修仙传 / A Record of a Mortal's Journey to Immortality", year: "2020", category: "剧集", episodes: ["S01E04", "S01E200"]))
            let answer = try await CustomTMDBService.lookup(request, config: config, session: session, progress: { _ in })
            try expect(answer.status == .matched && answer.details?.id == 107371, "Aliases did not resolve the same work")
            try expect(TMDBTitleMatching.queries("凡人修仙传/凡人修仙传").count == 2, "Repeated aliases were not bounded and deduplicated")
        }
        await run("ambiguous names and conflicting years remain manual choices") {
            let request = TMDBMatch.Request(video: Video("凡人修仙传", year: "2020", category: "剧集"))
            let first = TMDBMatch.SearchResult(mediaType: .tv, id: 1, name: "凡人修仙传", originalName: nil, year: 2020, poster: nil, backdrop: nil, overview: nil, sources: 0)
            let second = TMDBMatch.SearchResult(mediaType: .tv, id: 2, name: "凡人修仙传", originalName: nil, year: 2020, poster: nil, backdrop: nil, overview: nil, sources: 0)
            try expect(TMDBTitleMatching.pick([first, second], request: request) == nil, "Ambiguous titles were auto-selected")
            var wrongYear = request; wrongYear.year = "2026"
            try expect(TMDBTitleMatching.pick([first], request: wrongYear) == nil, "Conflicting release year was ignored")
        }
        await run("mixed source seasons retain the identified work") {
            let request = TMDBMatch.Request(video: Video("凡人修仙传", year: "2020", category: "剧集", episodes: ["S01E04", "S02E04"]))
            let answer = try await CustomTMDBService.lookup(request, config: config, session: session, progress: { _ in })
            try expect(answer.status == .matched && answer.details?.cast.count == 2, "Multiple source seasons hid an unambiguous work")
            try expect(answer.details?.episodes(for: request.episodes, numbering: .season).last! == nil, "Unaligned season borrowed metadata")
        }
        await run("source URLs are never used as TMDB search aliases") {
            let request = TMDBMatch.Request(video: Video("https://media.fixture/private-film"))
            let answer = try await CustomTMDBService.lookup(request, config: config, session: session, progress: { _ in })
            try expect(answer.status == .notFound && FixtureServer.shared.calls.isEmpty, "A playback URL was sent to metadata search")
        }
        await run("explicit refresh bypasses HTTP metadata cache") {
            _ = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session, refresh: true)
            try expect(FixtureServer.shared.calls.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData && $0.value(forHTTPHeaderField: "Cache-Control") == "no-cache" }, "Some metadata requests ignored refresh")
        }
        await run("profile links return biography and filmography") {
            let person = try await CustomTMDBService.person(1, language: "zh-CN", config: config, session: session)
            try expect(person.profile != nil && person.biography == "测试人物简介" && person.works.first?.item.id == 107371, "Person details or filmography missing")
        }
        await run("catalog people and keyword searches preserve pagination") {
            let people = try await CustomTMDBService.catalogSearch(query: "测试演员", kind: .person, page: 2, feed: .popular, filter: nil, personID: nil, keywords: false, language: "zh-CN", config: config, session: session)
            try expect(people.people.count == 1 && people.items.isEmpty && people.page == 2 && people.totalPages == 3, "People search pagination was lost")
            let keywords = try await CustomTMDBService.catalogSearch(query: "修仙", kind: .tv, page: 1, feed: .popular, filter: nil, personID: nil, keywords: true, language: "zh-CN", config: config, session: session)
            try expect(keywords.keywords.first?.name == "修仙" && keywords.totalPages == 2, "Keyword search failed")
        }
        await run("connection diagnostics decode each image type") {
            let checks = try await config.testConnection(session: session)
            try expect(checks.count == 7 && checks.allSatisfy { $0.status == .passed }, "A working API/image path did not pass all checks")
        }
        await run("connection diagnostics stop immediately on invalid credentials") {
            FixtureServer.shared.reset { _, _ in Reply("{}", status: 401) }
            let checks = try await config.testConnection(session: session)
            try expect(checks.count == 1 && checks[0].status == .failed && FixtureServer.shared.calls.count == 1, "Invalid credentials triggered unrelated image requests")
        }
        await run("broken portraits fail their own diagnostic while metadata stays valid") {
            FixtureServer.shared.reset { request, _ in request.url!.lastPathComponent == "actor.jpg" ? Reply("not an image") : standardReply(request) }
            let checks = try await config.testConnection(session: session)
            try expect(checks.first { $0.title == "演员头像" }?.status == .failed, "Non-image portrait data was accepted")
            try expect(checks.first { $0.title == "影片资料" }?.status == .passed, "An artwork failure invalidated metadata")
        }
        await run("old detail payloads decode without new optional warnings") {
            let details = try await CustomTMDBService.details(.tv, id: 107371, season: 1, language: "zh-CN", config: config, session: session)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(details)) as! [String: Any]
            object.removeValue(forKey: "metadataWarnings")
            let restored = try JSONDecoder().decode(TMDBMatch.Details.self, from: JSONSerialization.data(withJSONObject: object))
            try expect(restored.id == details.id && restored.metadataWarnings == nil, "Old metadata became undecodable")
        }
        await run("obsolete negative answers expire while manual choices persist") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yingxia-tmdb-store-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = directory.appendingPathComponent("cache.json"), choices = directory.appendingPathComponent("choices.json")
            let answer = TMDBMatch.Answer(status: .notFound, match: nil, season: nil, numbering: .season, unmatched: "", candidates: [], details: nil)
            let legacy = TMDBMatchStore.Entry(answer: answer, saved: Date(), version: 2)
            try JSONEncoder().encode(["fixture":legacy]).write(to: cache)
            let store = TMDBMatchStore(cacheURL: cache, choicesURL: choices)
            let obsolete = await store.answer(for: "fixture")
            try expect(obsolete == nil, "The old matcher retained a stale negative answer")
            await store.choose(.work(.tv, 107371, season: 1), for: "fixture")
            await store.save(answer, for: "fixture")
            let choice = await store.choice(for: "fixture")
            try expect(choice == .work(.tv, 107371, season: 1), "Refreshing an answer erased a manual choice")
            let expired = await store.answer(for: "fixture", now: Date().addingTimeInterval(2 * 86400))
            try expect(expired == nil, "Negative answers failed to expire")
        }
        return results
    }
}
