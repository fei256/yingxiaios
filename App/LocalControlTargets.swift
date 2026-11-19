import SwiftUI

extension View {
    /// Hit the complete visible navigation slot, including its inner capsule padding.
    func localDockControlTarget(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height).contentShape(Rectangle())
    }

    /// Empty painted edges must not open a poster underneath the floating dock.
    func localDockTouchSurface() -> some View {
        background {
            Capsule().fill(Color.black.opacity(0.001)).contentShape(Capsule()).onTapGesture {}
        }
    }
}
