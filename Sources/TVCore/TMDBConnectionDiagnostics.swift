import Foundation
import ImageIO

extension TMDBServiceSettings {
    public struct ConnectionCheck: Identifiable, Sendable {
        public enum Status: Equatable, Sendable { case passed, warning, failed }
        public let title: String
        public let message: String
        public let status: Status
        public var id: String { title }
    }

    /// Uses the draft configuration without saving or changing the active service.
    /// API, metadata and artwork checks follow the same transport as the detail page.
    public func testConnection(title: String = "凡人修仙传", session: URLSession = .shared) async throws -> [ConnectionCheck] {
        let config = custom ?? self
        var checks: [ConnectionCheck] = []
        func failure(_ title: String, _ error: Error) -> ConnectionCheck {
            ConnectionCheck(title: title, message: TMDBConnectionError.message(for: error), status: .failed)
        }
        do {
            _ = try config.proxyConfiguration()
            let value = try await CustomTMDBService.object("configuration", config: config, session: session, refresh: true, timeout: 12)
            guard value["images"] is [String: Any] else { throw TMDBConnectionError.invalidResponse }
            checks.append(ConnectionCheck(title: "API 与凭据", message: "TMDB API 验证通过。", status: .passed))
        } catch {
            try Task.checkCancellation()
            return [failure("API 与凭据", error)]
        }
        let results: [TMDBMatch.SearchResult]
        do {
            let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
            results = try await CustomTMDBService.search(query.isEmpty ? "凡人修仙传" : query, language: config.language,
                                                        config: config, session: session, refresh: true)
            checks.append(ConnectionCheck(title: "影片搜索", message: "搜索成功，返回 \(results.count) 部作品。", status: results.isEmpty ? .warning : .passed))
        } catch {
            try Task.checkCancellation()
            checks.append(failure("影片搜索", error)); return checks
        }
        guard let work = results.first else { return checks }
        let details: TMDBMatch.Details
        do {
            details = try await CustomTMDBService.details(work.mediaType, id: work.id, season: nil, language: config.language,
                                                         config: config, session: session, refresh: true)
            let episodes = details.season?.episodes.count ?? 0
            checks.append(ConnectionCheck(title: "影片资料", message: "\(details.name) · \(details.cast.count) 位演员 · \(episodes) 集资料。",
                                          status: details.metadataWarnings == nil ? .passed : .warning))
            for (index, warning) in (details.metadataWarnings ?? []).enumerated() {
                checks.append(ConnectionCheck(title: "剧集资料 \(index + 1)", message: warning, status: .warning))
            }
        } catch {
            try Task.checkCancellation()
            checks.append(failure("影片资料", error)); return checks
        }
        let artwork: [(String, URL?)] = [
            ("海报与背景", details.backdrop ?? details.poster),
            ("演员头像", details.cast.compactMap(\.profile).first),
            ("剧集缩略图", details.season?.episodes.compactMap(\.still).first),
            ("片名图片", details.logo),
        ]
        for (title, address) in artwork {
            try Task.checkCancellation()
            guard let address else {
                checks.append(ConnectionCheck(title: title, message: "TMDB 暂未提供这类图片。", status: .warning)); continue
            }
            do {
                let data = try await Self.artworkData(for: address, settings: config, session: session)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
                    throw TMDBConnectionError.invalidResponse
                }
                checks.append(ConnectionCheck(title: title, message: "图片读取成功。", status: .passed))
            } catch {
                try Task.checkCancellation()
                checks.append(failure(title, error))
            }
        }
        return checks
    }
}
