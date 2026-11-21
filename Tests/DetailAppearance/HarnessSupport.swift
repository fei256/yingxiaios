import Foundation
import SwiftUI
import UIKit

// The layout host has fixed images and no media runtime. Production view bodies
// are copied unchanged except for module imports; observation is supplied here.
struct WithPerceptionTracking<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}
extension View {
    @ViewBuilder
    func appOnChange<Value: Equatable>(of value: Value, _ action: @escaping (Value, Value) -> Void) -> some View {
        if #available(iOS 17, *) { onChange(of: value) { old, new in action(old, new) } }
        else { onChange(of: value) { new in action(value, new) } }
    }
}
enum TMDBMatch {
    struct Trailer: Sendable { let key: String }
}
struct DiscoverTrailer: View {
    init(trailer: TMDBMatch.Trailer, ready: @escaping (Bool) -> Void = { _ in }) {}
    var body: some View { EmptyView() }
}
enum JSONValue: Sendable {
    case string(String), object([String: JSONValue]), number(Double)
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
}
enum MobileMediaServices {
    static func call(_ method: String, _ parameters: [String: JSONValue]) async throws -> JSONValue { throw URLError(.unsupportedURL) }
}
struct HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url); request.allHTTPHeaderFields = headers
        return try await URLSession.shared.data(for: request)
    }
}

final class FixtureImages: @unchecked Sendable {
    static let shared = FixtureImages()
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    func read(_ name: String) -> Data? { lock.withLock { files[name] } }
    @MainActor func prepare() {
        let background = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 680)).pngData { context in
            let colors = [UIColor(red: 0.12, green: 0.43, blue: 0.53, alpha: 1).cgColor,
                          UIColor(red: 0.05, green: 0.28, blue: 0.38, alpha: 1).cgColor,
                          UIColor(red: 0.20, green: 0.36, blue: 0.43, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1200, y: 680), options: [])
            UIColor.white.withAlphaComponent(0.05).setStroke()
            for x in stride(from: -600, through: 1400, by: 130) {
                let curve = UIBezierPath(); curve.move(to: CGPoint(x: x, y: 0)); curve.addLine(to: CGPoint(x: x + 400, y: 680))
                curve.lineWidth = 40; curve.stroke()
            }
        }
        let wordmark = UIGraphicsImageRenderer(size: CGSize(width: 520, height: 160)).pngData { _ in
            let text = "凡人修仙传" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font:UIFont.systemFont(ofSize: 72, weight: .semibold),
                                                            .foregroundColor:UIColor(red: 0.98, green: 0.88, blue: 0.44, alpha: 1)]
            text.draw(at: CGPoint(x: 70, y: 34), withAttributes: attributes)
        }
        lock.withLock { files = ["background.png": background, "logo.png": wordmark] }
        _ = URLProtocol.registerClass(FixtureImageProtocol.self)
    }
}
final class FixtureImageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "images.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let data = FixtureImages.shared.read(request.url!.lastPathComponent) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
