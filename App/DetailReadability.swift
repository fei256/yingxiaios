import SwiftUI

/// White metadata needs a stable dark surface regardless of the poster's sampled colour.
struct DetailReadabilityOverlay: View {
    var body: some View {
        LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
