/// Disk coverage and decoder buffering have different lifetimes. A verified
/// complete cache covers the whole timeline, including after a seek or pause.
public enum PlaybackCacheProgress {
    public static func bufferedRanges(duration: Double, position: Double, decodedThrough: Double,
                                      cacheComplete: Bool, cachedRanges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard duration.isFinite, duration > 0 else { return [] }
        if cacheComplete { return [0...1] }
        let end = bufferedPosition(duration: duration, decodedThrough: decodedThrough, cacheComplete: false)
        let start = max(0, position)
        guard position.isFinite, start < end else { return cachedRanges }
        return cachedRanges + [(start / duration)...(end / duration)]
    }

    public static func bufferedPosition(duration: Double, decodedThrough: Double, cacheComplete: Bool) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        if cacheComplete { return duration }
        return decodedThrough.isFinite ? min(duration, max(0, decodedThrough)) : 0
    }
}
