import Foundation

// Only the unrelated danmaku provider/cache dependencies are fixtures. The
// tested preference observer and reload methods are the production declaration.
enum TVError: LocalizedError { case unsupported(String) }
enum L10n { static func text(_ value: String) -> String { value } }
struct PlaybackHistoryContext: Sendable { var id = "fixture"; var videoName = "Fixture"; var year: String? }
struct CatalogDanmakuComment: Codable, Sendable {
    enum Mode: Codable, Sendable { case scroll, top, bottom }
    var time: Double; var mode: Mode; var color: UInt32; var text: String
}
struct Danmaku: Sendable {
    enum Position: Sendable { case scroll, top, bottom }
    var time: Double; var position: Position; var color: UInt32; var text: String
}
struct AutomaticDanmakuResult: Codable, Sendable {
    let comments: [CatalogDanmakuComment], track: String, source: String, state: String
    var cached = false
}
struct CatalogDanmakuEpisode: Sendable { var id: String; var title: String }
struct CatalogDanmakuAnime: Sendable { var title: String }
struct DanmakuTrack: Sendable { var number: Int?; var title: String; var id: String }
struct DanmakuMapping: Sendable { var provider: String; var title: String; var year: String?; var tracks: [DanmakuTrack] }
enum CatalogDanmakuMatcher { static func episodeNumber(_ value: String) -> Int? { nil } }
enum CatalogDanmakuParser {
    static let maximumBytes = 1024
    static func parse(_ data: Data) throws -> [CatalogDanmakuComment] { [] }
}
struct CatalogDanmakuClient: Sendable {
    static let defaultServer = "https://fixture.invalid"
    let server = URL(string: Self.defaultServer)!
    func comments(_ episode: CatalogDanmakuEpisode) async throws -> [CatalogDanmakuComment] { [] }
}
final class MediaCache: Sendable {
    struct Ticket: Sendable {}
    enum Kind { case danmaku }
    static let shared = MediaCache()
    func ticket() -> Ticket { Ticket() }
    func remove(_ key: String, kind: Kind, scope: String) {}
    func store(_ data: Data, for key: String, kind: Kind, scope: String, ttl: Double, ticket: Ticket) {}
}
struct DanmakuResolver: Sendable {
    init(dandanServer: String, dmkuServer: URL? = nil, officialLookup: Bool = true) {}
    static func episodeKey(_ context: PlaybackHistoryContext) -> String { context.id }
    func forgetUnreachableServers() {}
    func remember(_ mapping: DanmakuMapping, for context: PlaybackHistoryContext, ticket: MediaCache.Ticket) {}
    func resolve(_ context: PlaybackHistoryContext, ticket: MediaCache.Ticket? = nil,
        first: @Sendable (PlaybackHistoryContext) async -> AutomaticDanmakuResult?) async throws -> AutomaticDanmakuResult {
        throw TVError.unsupported("No provider requests are allowed in settings checks")
    }
}
enum CatPawDanmaku {
    static func comments(for context: PlaybackHistoryContext) async -> AutomaticDanmakuResult? { nil }
}
