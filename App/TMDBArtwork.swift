import Foundation
import ImageIO
import SwiftUI
import Perception
import TVCore

/// Large artwork and transparent logos share the configured TMDB image transport.
struct TMDBArtwork: View {
    @AppStorage("local.tmdb.custom.v1") private var tmdbSettings = Data()
    let url: URL
    var maxPixels = 1600
    /// Fills its frame (a backdrop) or fits in it (a logo).
    var fill = true
    var aspect: Binding<CGFloat?>? = nil
    @State private var image: CGImage?
    private static let cache: NSCache<NSURL, Box> = { let cache = NSCache<NSURL, Box>(); cache.countLimit = 24; return cache }()
    final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private var artworkURL: URL { _ = tmdbSettings; return TMDBServiceSettings.artworkURL(url) }

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: artworkURL.absoluteString + "|" + tmdbSettings.base64EncodedString()) {
                let url = artworkURL
                if let cached = Self.cache.object(forKey: url as NSURL) { show(cached.image); return }
                guard let decoded = await Self.load(url, maxPixels: maxPixels), !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { show(decoded) }
            }
        }
    }

    /// Downloads and decodes `url` into the shared cache; nil when it doesn't load.
    static func load(_ url: URL, maxPixels: Int) async -> CGImage? {
        let url = TMDBServiceSettings.artworkURL(url)
        if let cached = cache.object(forKey: url as NSURL) { return cached.image }
        guard let data = try? await TMDBServiceSettings.artworkData(for: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        cache.setObject(Box(decoded), forKey: url as NSURL)
        return decoded
    }

    private func show(_ decoded: CGImage) {
        image = decoded
        aspect?.wrappedValue = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
    }
}
