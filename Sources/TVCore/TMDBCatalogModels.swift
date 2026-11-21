import Foundation

/// Catalog data shared by the built-in and native TMDB services.
public enum TMDBCatalog {
    public enum Feed: String, Codable, CaseIterable, Sendable {
        case trending, movies, television, onTheAir, nowPlaying, upcoming, topMovies, topTelevision, animation, chinese, korean, variety
        case family, kids, netflix, disney, appleTV, hbo, warner, universal, paramount, sony
        /// Discover's featured carousel: IMDb's popular charts mixed with Douban's hot lists, as TMDB titles (#631).
        case featured
    }

    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let mediaType: TMDBMatch.MediaType
        public let name: String
        public let originalName: String
        public let year: Int?
        public let date: String?
        public let overview: String
        public let poster: URL?
        public let backdrop: URL?
        public let rating: Double?
        public let genreIDs: [Int]
        public var key: String { "\(mediaType.rawValue):\(id)" }

        public init(id: Int, mediaType: TMDBMatch.MediaType, name: String, originalName: String, year: Int?, overview: String,
                    poster: URL?, backdrop: URL?, rating: Double?, genreIDs: [Int], date: String? = nil) {
            self.id = id; self.mediaType = mediaType; self.name = name; self.originalName = originalName
            self.year = year; self.overview = overview; self.poster = poster; self.backdrop = backdrop
            self.rating = rating; self.genreIDs = genreIDs; self.date = date
        }
    }

    public struct Page: Codable, Sendable {
        public let items: [Item]
        public let page: Int
        public let totalPages: Int
        /// Local fetch time survives reuse by a new Home model. It is not part of the remote protocol.
        public var fetchedAt: Date? = nil
        private enum CodingKeys: String, CodingKey { case items, page, totalPages }
    }

    public struct Person: Codable, Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let profile: URL?
        public let works: [Item]
    }

    public struct Brand: Codable, Sendable, Identifiable {
        public let feed: Feed
        public let name: String
        public let logo: URL?
        public var id: Feed { feed }
    }

    public struct Collections: Codable, Sendable {
        public let people: [Person]
        public let networks: [Brand]
        public let companies: [Brand]
    }

}

extension TMDBCatalog {
    public enum SearchKind: String, Codable, CaseIterable, Sendable { case movie, tv, person }
    public enum SearchFeed: String, Codable, CaseIterable, Sendable { case day, week, popular }
    public struct SearchPerson: Codable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let profile: URL?
        public let department: String?
        public let works: [Item]
    }
    public struct Keyword: Codable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let name: String
    }
    public struct SearchPage: Codable, Sendable {
        public let items: [Item]
        public let people: [SearchPerson]
        public let keywords: [Keyword]
        public let page: Int
        public let totalPages: Int
    }
    public struct Filter: Codable, Hashable, Sendable {
        public var kind: SearchKind = .movie
        public var genres: Set<Int> = []
        public var sort = "popularity.desc"
        public var from = ""
        public var to = ""
        public var originalLanguage = ""
        public var region = ""
        public var company = ""
        public var rating = 0
        public var votes = 0
        public var minRuntime = ""
        public var maxRuntime = ""
        public var keywords: [Keyword] = []
        public init() {}
        public var parameters: [String: String] {
            ["genres": genres.sorted().map(String.init).joined(separator: ","), "sort": sort, "from": from, "to": to,
             "originalLanguage": originalLanguage, "region": region, kind == .tv ? "networks" : "companies": company,
             "rating": String(rating), "votes": String(votes), "minRuntime": minRuntime, "maxRuntime": maxRuntime,
             "keywords": keywords.map { String($0.id) }.joined(separator: ",")]
        }
        public var isValid: Bool {
            func number(_ text: String, _ range: ClosedRange<Int>) -> Bool {
                text.isEmpty || (text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) && Int(text).map(range.contains) == true)
            }
            return number(from, 1870...2100) && number(to, 1870...2100)
                && number(minRuntime, 0...600) && number(maxRuntime, 0...600)
                && (from.isEmpty || to.isEmpty || Int(from)! <= Int(to)!)
                && (minRuntime.isEmpty || maxRuntime.isEmpty || Int(minRuntime)! <= Int(maxRuntime)!)
        }
    }

}

extension TMDBCatalog {
    public struct PersonWork: Codable, Hashable, Sendable, Identifiable {
        public let item: Item
        public let date: String?
        public let roles: [String]
        public let departments: [String]
        public var id: String { item.key }
    }
    public struct PersonProfile: Codable, Sendable {
        public let id: Int
        public let name: String
        public let profile: URL?
        public let biography: String
        public let birthday: String?
        public let birthplace: String
        public let department: String
        public let instagram: String?
        public let works: [PersonWork]
    }
}
