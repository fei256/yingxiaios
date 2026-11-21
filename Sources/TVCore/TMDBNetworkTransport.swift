import Foundation

public enum TMDBConnectionError: LocalizedError, Equatable, Sendable {
    case http(Int)
    case invalidResponse
    case network(Int)

    public var errorDescription: String? {
        switch self {
        case .http(401): "TMDB 凭据无效或未填写，请检查 API Key / Read Access Token（HTTP 401）。"
        case .http(403): "TMDB 拒绝访问，请检查凭据权限及网络（HTTP 403）。"
        case .http(404): "TMDB 地址或资料不存在，请检查 API 地址（HTTP 404）。"
        case .http(407): "代理认证失败，请检查代理账号和密码（HTTP 407）。"
        case .http(429): "TMDB 请求过于频繁，请稍后重试（HTTP 429）。"
        case .http(let status): "TMDB 服务返回 HTTP \(status)，请稍后重试。"
        case .invalidResponse: "TMDB 返回的资料格式无效，请检查 API 地址。"
        case .network(let code):
            switch URLError.Code(rawValue: code) {
            case .timedOut: "TMDB 连接超时，请检查网络或代理。"
            case .notConnectedToInternet: "网络未连接，请联网后重试。"
            case .cannotFindHost, .dnsLookupFailed: "无法解析 TMDB 地址，请检查 API 地址及 DNS。"
            case .secureConnectionFailed, .serverCertificateUntrusted: "TMDB 安全连接失败，请检查网络及证书。"
            case .badURL: "TMDB 配置无效，请检查 API、图片和代理地址。"
            default: "无法连接 TMDB，请检查网络或代理后重试。"
            }
        }
    }

    /// Diagnostics must never echo an authenticated request URL or proxy secret.
    public static func message(for error: Error) -> String {
        if let failure = error as? Self { return failure.localizedDescription }
        if let failure = error as? URLError { return Self.network(failure.code.rawValue).localizedDescription }
        return Self.network(URLError.cannotConnectToHost.rawValue).localizedDescription
    }
}

extension TMDBServiceSettings {
    /// Direct requests retain the caller's cache/session. Only the explicitly
    /// configured TMDB proxy enters the embedded mobile HTTP/SOCKS transport.
    func data(for request: URLRequest, session: URLSession) async throws -> Data {
        #if os(iOS) || os(tvOS)
        if let proxy = try proxyConfiguration() {
            guard let url = request.url else { throw URLError(.badURL) }
            let response: JSONValue
            do {
                response = try await MobileMediaServices.call("tmdb.fetch", [
                    "url": .string(url.absoluteString),
                    "proxy": .object(proxy.mapValues(JSONValue.string)),
                    "headers": .object((request.allHTTPHeaderFields ?? [:]).mapValues(JSONValue.string)),
                ])
            } catch {
                try Task.checkCancellation()
                let message = error.localizedDescription
                if let range = message.range(of: #"HTTP\s+\d{3}"#, options: .regularExpression),
                   let status = Int(message[range].suffix(3)) { throw TMDBConnectionError.http(status) }
                throw TMDBConnectionError.network(URLError.cannotConnectToHost.rawValue)
            }
            guard let encoded = response.object?["data"]?.string, let data = Data(base64Encoded: encoded) else {
                throw URLError(.cannotDecodeContentData)
            }
            return data
        }
        #endif
        for attempt in 0..<2 {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TMDBConnectionError.invalidResponse }
            if (200..<300).contains(http.statusCode) {
                guard data.count <= 24 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                return data
            }
            if attempt == 0, [429, 502, 503, 504].contains(http.statusCode) {
                let delay = min(3, max(0.1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0.5))
                try await Task.sleep(for: .seconds(delay))
            } else { throw TMDBConnectionError.http(http.statusCode) }
        }
        throw TMDBConnectionError.invalidResponse
    }

    public static func artworkData(for url: URL, headers: [String: String] = [:], settings: Self? = nil,
                                   session: URLSession = .shared) async throws -> Data {
        let settings = settings ?? load()
        var request = URLRequest(url: artworkURL(url, settings: settings), timeoutInterval: 30)
        request.allHTTPHeaderFields = headers
        if settings.isArtwork(url) { return try await settings.data(for: request, session: session) }
        return try await HTTPClient().get(url, headers: headers).0
    }
}
