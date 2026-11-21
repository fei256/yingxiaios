/// Disk coverage and decoder buffering have different lifetimes. A verified
/// complete cache covers the whole timeline, including after a seek or pause.
public enum PlaybackCacheProgress {
    public static func bufferedPosition(duration: Double, decodedThrough: Double, cacheComplete: Bool) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        if cacheComplete { return duration }
        return decodedThrough.isFinite ? min(duration, max(0, decodedThrough)) : 0
    }
}
