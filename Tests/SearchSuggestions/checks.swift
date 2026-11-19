import Foundation

// The standalone checks compile the production suggestion code without the full media runtime.
enum HTTPClient { static let userAgent = "Yingxia-Search-Checks" }

private final class StubResponse: @unchecked Sendable {
    let lock = NSLock()
    private var data = Data()
    private var status = 200
    private var requests: [URLRequest] = []

    func configure(_ json: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        data = Data(json.utf8); self.status = status; requests = []
    }
    func answer(_ request: URLRequest) -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return (data, status)
    }
    var recorded: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let response = StubResponse()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status) = Self.response.answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main private struct SearchSuggestionChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() async {
        let candidates = ["复仇者联盟", "庆余年", "西游记", " F1：狂飙飞车 ", "复仇者联盟", " "]
        check(SearchSuggestions.matchingTitles(for: "f", in: candidates) == ["复仇者联盟", "F1：狂飙飞车"], "One letter must match Chinese pinyin and English titles")
        check(SearchSuggestions.matchingTitles(for: "FCZLM", in: candidates) == ["复仇者联盟"], "Pinyin initials must ignore letter case")
        check(SearchSuggestions.matchingTitles(for: "qing yu nian", in: candidates) == ["庆余年"], "Full pinyin must tolerate spaces")
        check(SearchSuggestions.matchingTitles(for: "庆", in: candidates) == ["庆余年"], "One Chinese character must match")
        check(SearchSuggestions.matchingTitles(for: " ", in: candidates).isEmpty, "Blank input must not suggest unrelated history")

        let json = #"{"data":[{"name":" 庆余年 "},{"name":""},{"name":"庆余年"},{"title":"wrong key"},{"name":"西游记"}]}"#
        check(SearchSuggestions.titles(in: Data(json.utf8), key: "name") == ["庆余年", "西游记"], "Provider titles must trim, omit blanks and deduplicate")
        check(SearchSuggestions.titles(in: Data(#"{"data":{}}"#.utf8), key: "name").isEmpty, "Unexpected provider schemas must be harmless")
        check(SearchSuggestions.titles(in: Data("invalid".utf8), key: "name").isEmpty, "Invalid JSON must leave explicit search available")
        let many = (0..<20).map { ["name": "Title \($0)"] }
        let manyData = try! JSONSerialization.data(withJSONObject: ["data": many])
        check(SearchSuggestions.titles(in: manyData, key: "name").count == SearchSuggestions.limit, "Suggestion lists must remain bounded")

        var state = SearchSuggestionState()
        let old = state.begin("f")
        let current = state.begin("庆")
        state.complete(["复仇者联盟"], revision: old)
        check(state.query == "庆" && state.titles.isEmpty && state.isLoading, "Late answers must not replace the latest draft")
        state.complete(["庆余年"], revision: current)
        check(state.titles == ["庆余年"] && !state.isLoading, "Current answers must publish")
        let pending = state.begin("x")
        state.cancel()
        state.complete(["西游记"], revision: pending)
        check(state.titles.isEmpty && !state.isLoading, "Submission or leaving the page must invalidate pending answers")
        let cleared = state.begin("")
        state.complete(["旧结果"], revision: pending)
        check(cleared != pending && state.query.isEmpty && state.titles.isEmpty && !state.isLoading, "Clearing input must reject old answers")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StubProtocol.response.configure(json)
        let empty = await SearchSuggestions.titles(for: " ", session: session)
        check(empty.isEmpty && StubProtocol.response.recorded.isEmpty, "Empty drafts must not issue network requests")
        let answer = await SearchSuggestions.titles(for: " 庆 ", session: session)
        check(answer == ["庆余年", "西游记"], "Production fetching must parse the provider response")
        let request = StubProtocol.response.recorded.first!
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(query.contains(URLQueryItem(name: "key", value: "庆")), "Chinese input must reach the provider without broken encoding")
        check(request.timeoutInterval == 5, "Suggestion requests must have a short timeout")
        StubProtocol.response.configure(json, status: 503)
        let failed = await SearchSuggestions.titles(for: "f", session: session)
        check(failed.isEmpty, "HTTP failure must not display unusable provider titles")
        print("Search suggestion checks passed: Chinese, pinyin, initials, response parsing, request encoding and stale answers.")
    }
}
