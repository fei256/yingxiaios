import Foundation

@main enum PlaybackCacheProgressChecks {
    static func main() {
        let duration = 18.0 * 60 + 15
        precondition(PlaybackCacheProgress.bufferedPosition(duration: duration, decodedThrough: 168, cacheComplete: true) == duration,
                     "A fully cached file fills the timeline even when the decoder buffers only a few minutes")
        for decoded in [0.0, 10, 168, 900] {
            precondition(PlaybackCacheProgress.bufferedPosition(duration: duration, decodedThrough: decoded, cacheComplete: true) == duration,
                         "A seek must not shorten verified disk coverage")
            precondition(PlaybackCacheProgress.bufferedPosition(duration: duration, decodedThrough: decoded, cacheComplete: false) == decoded,
                         "Incomplete, evicted or disabled caches retain measured decoder buffering")
        }
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            precondition(PlaybackCacheProgress.bufferedPosition(duration: invalid, decodedThrough: 20, cacheComplete: true) == 0)
        }
        precondition(PlaybackCacheProgress.bufferedPosition(duration: duration, decodedThrough: .nan, cacheComplete: false) == 0)
        precondition(PlaybackCacheProgress.bufferedPosition(duration: duration, decodedThrough: -20, cacheComplete: false) == 0)
        precondition(PlaybackCacheProgress.bufferedPosition(duration: duration, decodedThrough: duration + 20, cacheComplete: false) == duration)
        let prefix = 0.0...(1.07 / 1.65)
        let island = 0.8...0.9
        func ranges(_ disk: [ClosedRange<Double>], complete: Bool = false, duration: Double = 1244) -> [ClosedRange<Double>] {
            PlaybackCacheProgress.bufferedRanges(duration: duration, position: 305, decodedThrough: 350,
                cacheComplete: complete, cachedRanges: disk)
        }
        let decoded = (305.0 / 1244)...(350.0 / 1244)
        precondition(ranges([prefix, island]) == [prefix, island, decoded])
        precondition(ranges([]) == [decoded])
        precondition(ranges([], complete: true) == [0...1])
        precondition(ranges([prefix], duration: .nan).isEmpty)
        print("Playback cache timeline checks passed.")
    }
}
