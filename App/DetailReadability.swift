import SwiftUI

/// The reading surface scrolls with its content, leaving the artwork above it unobscured.
struct DetailReadabilityOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.58), location: min(1, 36 / max(geometry.size.height, 1))),
                .init(color: .black.opacity(0.68), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    func detailReadableContent() -> some View {
        background {
            DetailReadabilityOverlay().padding(.horizontal, -20).padding(.top, -36).padding(.bottom, -24)
        }
    }

    func detailArtworkToolbarShade() -> some View {
        overlay(alignment: .top) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.60), location: 0),
                .init(color: .black.opacity(0.48), location: 0.60),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: 180).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
