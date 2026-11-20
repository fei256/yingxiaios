import SwiftUI

extension View {
    func detailReadableContent() -> some View {
        shadow(color: .black.opacity(0.22), radius: 1, y: 1)
    }

    func detailArtworkToolbarShade() -> some View {
        overlay(alignment: .top) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.32), location: 0),
                .init(color: .black.opacity(0.12), location: 0.55),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: 130).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
