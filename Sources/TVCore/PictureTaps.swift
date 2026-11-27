import Foundation

/// Sliding sideways across the picture moves through the video (Bilibili, Tencent Video): the picture's width is up
/// to three minutes, or the whole video when it is shorter.
public enum PictureSeek {
    public static let span = 180.0

    public static func target(from start: Double, moved x: Double, width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0, duration.isFinite, start.isFinite, x.isFinite else { return start }
        return min(max(0, start + x / width * min(duration, span)), duration)
    }
}

/// Sliding up or down the picture sets the screen's brightness on its left half and the volume on its right (Bilibili,
/// Tencent Video): three quarters of the picture's height is the whole range.
public enum PictureLevel {
    public static let key = "player.slidesLevels"
    /// Slides that start this close to the top or bottom are left to Notification Center, Control Center and the
    /// Home indicator.
    public static let edge = 44.0

    public static func slides(fromY y: Double, height: Double) -> Bool { y >= edge && y <= height - edge }

    public static func value(from start: Double, moved y: Double, height: Double) -> Double {
        guard height > 0, start.isFinite, y.isFinite else { return start }
        return min(max(0, start - y / (height * 0.75)), 1)
    }
}
