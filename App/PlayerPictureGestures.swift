#if os(iOS)
import SwiftUI
import UIKit
#if canImport(TVCore)
import TVCore
#endif

/// The picture's own gestures, in UIKit: taps, a touch and hold followed while the finger moves, slides and a pinch.
/// SwiftUI's long press ends where a drag would begin, and a tap beside it can fire as the held finger lifts.
struct PictureGestures: UIViewRepresentable {
    enum Hold { case began, moved(CGSize), ended }
    /// Sideways seeks; up or down sets the brightness on the left half and the volume on the right.
    enum Slide { case seek, brightness, volume }
    enum Swipe { case began(Slide), moved(CGSize, in: CGSize), ended }
    /// Where the tap landed across the picture, and the picture's width.
    let tap: (CGFloat, CGFloat) -> Void
    let hold: (Hold) -> Void
    let swipe: (Swipe) -> Void
    /// Whether slides up or down set the brightness and the volume.
    var levels = true
    var excludedHitRegions: [CGRect] = []
    /// Pinched out (true) or in, as in YouTube: fill the screen or fit the picture.
    let pinch: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = PictureGestureSurface()
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.35
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        // A touch that lifts before the hold begins is a tap, at once; each tap of a double tap comes on its own.
        tap.require(toFail: press)
        // A finger that moves before the hold begins slides instead.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        for recognizer in [press, tap, pan, pinch] { view.addGestureRecognizer(recognizer) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        (view as? PictureGestureSurface)?.excludedHitRegions = excludedHitRegions.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
    }

    private final class PictureGestureSurface: UIView {
        var excludedHitRegions: [CGRect] = []
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event), let window else { return false }
            let location = convert(point, to: window)
            return !excludedHitRegions.contains { $0.contains(location) }
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PictureGestures?
        private var start = CGPoint.zero
        private var slide = Slide.seek

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view else { return }
            parent?.tap(tap.location(in: view).x, view.bounds.width)
        }

        @objc func pressed(_ press: UILongPressGestureRecognizer) {
            let location = press.location(in: press.view)
            switch press.state {
            case .began: start = location; parent?.hold(.began)
            case .changed: parent?.hold(.moved(CGSize(width: location.x - start.x, height: location.y - start.y)))
            case .ended, .cancelled, .failed: parent?.hold(.ended)
            default: break
            }
        }

        @objc func panned(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            switch pan.state {
            case .began: parent?.swipe(.began(slide))
            case .changed:
                let moved = pan.translation(in: view)
                parent?.swipe(.moved(CGSize(width: moved.x, height: moved.y), in: view.bounds.size))
            case .ended, .cancelled, .failed: parent?.swipe(.ended)
            default: break
            }
        }

        @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
            guard pinch.state == .ended, abs(pinch.scale - 1) > 0.1 else { return }
            parent?.pinch(pinch.scale > 1)
        }

        /// Sideways anywhere; up or down only away from the edges that Notification Center, Control Center and the
        /// Home indicator use.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            if abs(velocity.x) > abs(velocity.y) { slide = .seek; return true }
            let location = pan.location(in: view)
            guard parent?.levels == true, PictureLevel.slides(fromY: location.y, height: view.bounds.height) else { return false }
            slide = location.x < view.bounds.width / 2 ? .brightness : .volume
            return true
        }
    }
}

#endif
