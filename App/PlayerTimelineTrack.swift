import SwiftUI

struct PlayerTimelineTrack: View {
    let played: Double
    let buffered: [ClosedRange<Double>]
    var thickness: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: thickness)
                Path { path in
                    for range in buffered {
                        let start = fraction(range.lowerBound) * geometry.size.width
                        let end = fraction(range.upperBound) * geometry.size.width
                        path.addRect(CGRect(x: start, y: 0, width: end - start, height: thickness))
                    }
                }
                .fill(.white.opacity(0.4))
                .frame(height: thickness)
                .clipShape(Capsule())
                Capsule().fill(.white).frame(width: geometry.size.width * fraction(played), height: thickness)
            }.frame(height: geometry.size.height)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func fraction(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}
