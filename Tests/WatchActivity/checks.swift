import Foundation

@main
enum WatchActivityChecks {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!
        var count = 0
        func check(_ name: String, _ body: () throws -> Bool) throws {
            guard try body() else { throw Failure(name: name) }
            count += 1
            print("Watch activity: \(name) passed")
        }
        func sample(_ sampler: inout PlaybackWatchSampler, _ tick: Double, _ position: Double,
                    identity: String = "show:a:episode:1", playing: Bool = true, speed: Double = 1, base: Date? = nil) {
            sampler.sample(identity: identity, playing: playing, position: position, speed: speed,
                           now: (base ?? start).addingTimeInterval(tick), uptime: 100 + tick, calendar: calendar)
        }
        func equal(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.0001 }

        try check("normal playback counts wall time") {
            var sampler = PlaybackWatchSampler()
            for tick in 0...5 { sample(&sampler, Double(tick), Double(tick)) }
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 5)
        }
        try check("playback speed does not multiply viewing time") {
            var sampler = PlaybackWatchSampler()
            for tick in 0...3 { sample(&sampler, Double(tick), Double(tick) * 8, speed: 8) }
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 3)
        }
        try check("pause and resume exclude stopped intervals") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 1, 1)
            sample(&sampler, 2, 1, playing: false); sample(&sampler, 3, 1, playing: false)
            sample(&sampler, 4, 1); sample(&sampler, 5, 2)
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 2)
        }
        try check("buffering and explicit seeking are excluded") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 10); sample(&sampler, 1, 11)
            sample(&sampler, 2, 11, playing: false); sample(&sampler, 3, 1000, playing: false)
            sample(&sampler, 4, 1000); sample(&sampler, 5, 1001)
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 2)
        }
        try check("unobserved forward seek cannot inflate viewing time") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 1, 600); sample(&sampler, 2, 601)
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 1)
        }
        try check("quick control transitions exclude the intervening paused time") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 0.25, 0.25)
            sample(&sampler, 0.25, 0.25, playing: false)
            sample(&sampler, 0.75, 0.25)
            sample(&sampler, 1, 0.5)
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 0.5)
        }
        try check("quick seek interruption preserves pending playback without bridging the jump") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 0.5, 0.5); sampler.interrupt()
            sample(&sampler, 0.75, 1); sample(&sampler, 1.75, 2)
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 1.5)
        }
        try check("rewatching accumulates while rewind establishes a baseline") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 1, 1)
            let first = sampler.drain(identity: "show:a:episode:1")
            sample(&sampler, 2, 0); sample(&sampler, 3, 1)
            return equal(first.merging(sampler.drain(identity: "show:a:episode:1")).totalSeconds, 2)
        }
        try check("long suspension gap is not counted") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 120, 120); sample(&sampler, 121, 121)
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 1)
        }
        try check("identity changes retain separate episode and subscription totals") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 1, 1)
            sample(&sampler, 2, 0, identity: "other:show:a:episode:1")
            sample(&sampler, 3, 1, identity: "other:show:a:episode:1")
            return equal(sampler.drain(identity: "show:a:episode:1").totalSeconds, 1)
                && equal(sampler.drain(identity: "other:show:a:episode:1").totalSeconds, 1)
        }
        try check("midnight and week boundary split the measured interval") {
            let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 23, minute: 59, second: 59))!
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0, base: midnight); sample(&sampler, 2, 2, base: midnight)
            let activity = sampler.drain(identity: "show:a:episode:1")
            return equal(activity.days["2026-11-22"] ?? 0, 1) && equal(activity.days["2026-11-23"] ?? 0, 1)
                && equal(activity.totalSeconds, 2)
        }
        try check("clock adjustment establishes a new baseline") {
            var sampler = PlaybackWatchSampler()
            sampler.sample(identity: "clock", playing: true, position: 0, now: start, uptime: 10, calendar: calendar)
            sampler.sample(identity: "clock", playing: true, position: 1, now: start.addingTimeInterval(61), uptime: 11, calendar: calendar)
            sampler.sample(identity: "clock", playing: true, position: 2, now: start.addingTimeInterval(62), uptime: 12, calendar: calendar)
            return equal(sampler.drain(identity: "clock").totalSeconds, 1)
        }
        try check("stationary position never counts a stalled engine") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 10); sample(&sampler, 1, 10); sample(&sampler, 2, 10)
            return sampler.drain(identity: "show:a:episode:1").isEmpty
        }
        try check("drain and repeated final sample cannot duplicate saved time") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 1, 1); sample(&sampler, 1, 1)
            let first = sampler.drain(identity: "show:a:episode:1")
            return equal(first.totalSeconds, 1) && sampler.drain(identity: "show:a:episode:1").isEmpty
        }
        try check("reset prevents stale samples entering another playback session") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 1, 1); sampler.reset()
            sample(&sampler, 2, 2)
            return sampler.drain(identity: "show:a:episode:1").isEmpty
        }
        try check("invalid positions do not bridge into a later valid sample") {
            var sampler = PlaybackWatchSampler()
            sample(&sampler, 0, 0); sample(&sampler, 1, .nan); sample(&sampler, 2, 2)
            return sampler.drain(identity: "show:a:episode:1").isEmpty
        }
        try check("invalid dates and seconds are removed from imports") {
            let activity = PlaybackWatchActivity(days: ["2026-11-20": 30, "2024-02-29": 2, "2026-02-29": 3,
                                                        "2026-13-01": 2, "bad": 2, "2026-11-21": -1,
                                                        "2026-11-22": .infinity, "2026-11-23": .nan, "2026-11-24": .greatestFiniteMagnitude])
            return activity.days.count == 2 && equal(activity.totalSeconds, 32)
        }
        try check("empty optional data and daily statistics round trip") {
            let empty = try JSONDecoder().decode(PlaybackWatchActivity.self, from: Data("{}".utf8))
            let activity = PlaybackWatchActivity(days: ["2026-11-20": 19 * 60, "2026-11-21": 61])
            let decoded = try JSONDecoder().decode(PlaybackWatchActivity.self, from: JSONEncoder().encode(activity))
            return empty.isEmpty && decoded == activity && equal(decoded.totalSeconds, 1201)
        }
        try check("viewing day keys remain Gregorian under another system calendar") {
            var buddhist = Calendar(identifier: .buddhist)
            buddhist.timeZone = calendar.timeZone
            return PlaybackWatchActivity.dayKey(for: start, calendar: buddhist) == "2026-11-20"
        }
        print("\(count) watch activity regression cases passed")
    }

    private struct Failure: Error { let name: String }
}
