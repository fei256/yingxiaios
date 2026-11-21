import SwiftUI

/// Shared timeline paint keeps disk completion visible beneath the playhead.
struct PlayerTimelineTrack: View {
    let played: Double
    let buffered: Double
    var thickness: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: thickness)
                Capsule().fill(.white.opacity(0.4)).frame(width: geometry.size.width * fraction(buffered), height: thickness)
                Capsule().fill(.white).frame(width: geometry.size.width * fraction(played), height: thickness)
            }.frame(height: geometry.size.height)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func fraction(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}
