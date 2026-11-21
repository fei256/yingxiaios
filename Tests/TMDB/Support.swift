import Foundation

// The metadata checks compile production adapters and models without the media
// runtime. Only unrelated source-video and general HTTP dependencies are fixtures.
public struct Episode: Sendable {
    public let name: String
    public let flag: String
    public init(_ name: String, flag: String = "line") { self.name = name; self.flag = flag }
}

public struct Video: Sendable {
    public var id = "fixture"
    public var name: String
    public var year: String?
    public var remarks = ""
    public var synopsis = ""
    public var category: String?
    public var episodes: [Episode] = []
    public init(_ name: String, year: String? = nil, category: String? = nil, episodes: [String] = []) {
        self.name = name; self.year = year; self.category = category; self.episodes = episodes.map { Episode($0) }
    }
}

enum L10n { static func resolvedLanguage() -> String { "zh-Hans" } }

struct HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url); request.allHTTPHeaderFields = headers
        return try await URLSession.shared.data(for: request)
    }
}
