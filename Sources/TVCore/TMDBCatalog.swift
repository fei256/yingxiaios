import Foundation

extension TMDBCatalog {
    public static func collections(language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> Collections {
        if let custom = TMDBServiceSettings.load().custom {
            return try await CustomTMDBService.collections(language: language, config: custom, session: session)
        }
        var parts = URLComponents(url: TMDBMatch.base.appending(path: "catalog/collections"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "language", value: language)]
        let (data, response) = try await session.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Collections.self, from: data)
    }

    public static func page(_ feed: Feed, page: Int = 1, language: String = TMDBMatch.language, session: URLSession = .shared, refresh: Bool = false) async throws -> Page {
        if feed == .featured { return try await FeaturedCatalog.page(language: language, session: session, refresh: refresh) }
        if let custom = TMDBServiceSettings.load().custom {
            return try await CustomTMDBService.page(feed, page: page, language: language, config: custom, session: session, refresh: refresh)
        }
        return try await builtinPage(feed, page: page, language: language, session: session, refresh: refresh)
    }

    static func builtinPage(_ feed: Feed, page: Int, language: String, session: URLSession, refresh: Bool = false) async throws -> Page {
        var parts = URLComponents(url: TMDBMatch.base.appending(path: "catalog"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "feed", value: feed.rawValue), URLQueryItem(name: "page", value: String(page)),
                            URLQueryItem(name: "language", value: language)]
        var request = URLRequest(url: parts.url!, timeoutInterval: feed == .featured ? 8 : 30)
        request.cachePolicy = refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        if refresh { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw TMDBMatch.Failure(code: "http", message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(Page.self, from: data)
    }
}
