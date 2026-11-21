import Foundation

extension TMDBCatalog {
    public static func search(query: String = "", kind: SearchKind = .movie, page: Int = 1, feed: SearchFeed = .week,
                              filter: Filter? = nil, personID: Int? = nil, keywords: Bool = false,
                              language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> SearchPage {
        if let custom = TMDBServiceSettings.load().custom {
            return try await CustomTMDBService.catalogSearch(query: query, kind: kind, page: page, feed: feed,
                filter: filter, personID: personID, keywords: keywords, language: language, config: custom, session: session)
        }
        var parts = URLComponents(url: TMDBMatch.base.appending(path: "catalog/search"), resolvingAgainstBaseURL: false)!
        let mode = personID != nil ? "person" : keywords ? "keywords" : filter != nil ? "discover" : query.isEmpty ? "recommend" : "search"
        var params = filter?.parameters ?? [:]
        params.merge(["mode": mode, "kind": (filter?.kind ?? kind).rawValue, "q": query, "page": String(page),
                      "feed": feed.rawValue, "language": language]) { _, new in new }
        if let personID { params["id"] = String(personID) }
        parts.queryItems = params.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await session.data(for: URLRequest(url: parts.url!, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TMDBMatch.Failure(code: "http", message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(SearchPage.self, from: data)
    }
}

extension TMDBCatalog {
    public static func person(_ id: Int, language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> PersonProfile {
        if let custom = TMDBServiceSettings.load().custom {
            return try await CustomTMDBService.person(id, language: language, config: custom, session: session)
        }
        var parts = URLComponents(url: TMDBMatch.base.appending(path: "catalog/search"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "mode", value: "profile"), URLQueryItem(name: "id", value: String(id)), URLQueryItem(name: "language", value: language)]
        let (data, response) = try await session.data(for: URLRequest(url: parts.url!, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(PersonProfile.self, from: data)
    }
}
