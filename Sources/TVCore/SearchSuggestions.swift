import Foundation

/// Titles to offer while someone types a search. iQiyi's suggestion service matches pinyin
/// initials ("xyj"), full pinyin ("qingyunian") or a few characters to real titles ("西游记", "庆余年"), so a remote needs only
/// a few letters; choosing a title then searches the sources for exactly that, which they match far better than a
/// fragment. 360kan's chart fills the list before anything is typed. Both are unofficial endpoints: any failure is an
/// empty list, and what was typed is never logged.
public enum SearchSuggestions {
    public static let limit = 8

    /// Titles for what was typed; empty when there is nothing to ask or the service doesn't answer.
    public static func titles(for query: String, session: URLSession = .shared) async -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, var components = URLComponents(string: "https://suggest.video.iqiyi.com/") else { return [] }
        components.queryItems = [URLQueryItem(name: "if", value: "mobile"), URLQueryItem(name: "key", value: query)]
        guard let url = components.url, let data = await fetch(url, session: session) else { return [] }
        return titles(in: data, key: "name")
    }

    /// What is popular now, for an empty search field.
    public static func trending(session: URLSession = .shared) async -> [String] {
        guard let url = URL(string: "https://api.web.360kan.com/v1/rank?cat=1"),
              let data = await fetch(url, headers: ["Referer": "https://www.360kan.com/rank/general"], session: session) else { return [] }
        return titles(in: data, key: "title")
    }

    /// Previously searched titles remain useful when the online service is unavailable.
    public static func matchingTitles(for query: String, in candidates: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let latinQuery = compact(query)
        let usesLatin = !latinQuery.isEmpty && latinQuery.unicodeScalars.allSatisfy { $0.isASCII }
        var seen = Set<String>()
        return Array(candidates.compactMap { candidate -> String? in
            let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(title).inserted else { return nil }
            if title.localizedCaseInsensitiveContains(query) { return title }
            guard usesLatin, let latin = title.applyingTransform(.toLatin, reverse: false) else { return nil }
            let syllables = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let initials = syllables.compactMap(\.first).map(String.init).joined()
            return syllables.joined().hasPrefix(latinQuery) || initials.hasPrefix(latinQuery) ? title : nil
        }.prefix(limit))
    }

    private static func compact(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    /// The titles in a `{"data": [{key: …}]}` answer, trimmed, without blanks or repeats, at most `limit`.
    static func titles(in data: Data, key: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        let titles = items.compactMap { ($0[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return Array(titles.prefix(limit))
    }

    /// A short wait: a suggestion that arrives after the next keystroke is no use.
    private static func fetch(_ url: URL, headers: [String: String] = [:], session: URLSession) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return data
    }
}

/// A cancelled or superseded request must never replace the current draft's suggestions.
public struct SearchSuggestionState {
    public private(set) var query = ""
    public private(set) var titles: [String] = []
    public private(set) var isLoading = false
    private var revision = 0

    public init() {}

    public mutating func begin(_ draft: String) -> Int {
        revision &+= 1
        query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        titles = []
        isLoading = !query.isEmpty
        return revision
    }

    public mutating func complete(_ titles: [String], revision request: Int) {
        guard request == revision else { return }
        var seen = Set<String>()
        self.titles = Array(titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(SearchSuggestions.limit))
        isLoading = false
    }

    public mutating func cancel() {
        revision &+= 1
        titles = []
        isLoading = false
    }
}
