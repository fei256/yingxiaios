import Foundation
import CoreGraphics

/// Layout values shared by the dock and accessories whose container may extend
/// beyond the dock's safe area (HTML) or start inside a navigation stack (actors).
public enum LocalDockLayout {
    public static let horizontalPadding: CGFloat = 12
    public static let topPadding: CGFloat = 8
    public static let bottomPadding: CGFloat = 6
    public static let musicHeight: CGFloat = 56
    public static let musicSpacing: CGFloat = 8
    public static let controlHeight: CGFloat = 50
    public static let groupPadding: CGFloat = 4
    public static let maximumWidth: CGFloat = 520
    public static let itemCount = 6
    public static var dockHeight: CGFloat { controlHeight + 2 * groupPadding }

    public struct Metrics: Equatable, Sendable {
        public let width: CGFloat
        public let buttonWidth: CGFloat
        public let padding: CGFloat
    }

    public static func metrics(availableWidth: CGFloat) -> Metrics {
        let width = availableWidth.isFinite ? max(0, min(maximumWidth, availableWidth)) : 0
        let padding = min(groupPadding, width / 2)
        return Metrics(width: width, buttonWidth: (width - 2 * padding) / CGFloat(itemCount), padding: padding)
    }

    public static func height(controlHeight: CGFloat) -> CGFloat {
        max(Self.controlHeight, controlHeight) + 2 * groupPadding
    }

    public static func inset(showsMusic: Bool, controlHeight: CGFloat = Self.controlHeight) -> CGFloat {
        topPadding + height(controlHeight: controlHeight) + bottomPadding + (showsMusic ? musicHeight + musicSpacing : 0)
    }

    /// The dock has fixed control sizes; its touch regions can be resolved in the
    /// same layout pass. Feeding measured anchors back through @State leaves the
    /// first music-strip frame empty, and can animate old hit frames after scrolling.
    public static func touchFrames(containerWidth: CGFloat, showsMusic: Bool, controlHeight: CGFloat = Self.controlHeight) -> [CGRect] {
        let availableWidth = max(0, containerWidth - 2 * horizontalPadding)
        let metrics = metrics(availableWidth: availableWidth)
        let left = horizontalPadding + max(0, (availableWidth - metrics.width) / 2)
        let top = topPadding + (showsMusic ? musicHeight + musicSpacing : 0)
        var frames: [CGRect] = []
        if showsMusic {
            frames.append(CGRect(x: left, y: topPadding, width: metrics.width, height: musicHeight))
        }
        frames.append(CGRect(x: left, y: top, width: metrics.width, height: height(controlHeight: controlHeight)))
        return frames
    }

    public static func accessoryBottom(containerBottom: CGFloat, safeAreaBottom: CGFloat,
                                       dockTop: CGFloat?, fallbackInset: CGFloat, gap: CGFloat = 12) -> CGFloat {
        if let dockTop, dockTop.isFinite, containerBottom.isFinite {
            return max(gap, containerBottom - dockTop + gap)
        }
        return max(0, safeAreaBottom) + max(0, fallbackInset) + gap
    }
}
