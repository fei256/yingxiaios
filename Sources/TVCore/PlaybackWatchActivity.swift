import Foundation

/// Measured playback time belongs to the local viewing day, independently of saved media position.
public struct PlaybackWatchActivity: Codable, Hashable, Sendable {
    private var values: [String: Double]
    public var days: [String: Double] {
        get { values }
        set { values = Self.cleaned(newValue) }
    }
    public var totalSeconds: Double { values.values.reduce(0, +) }
    public var isEmpty: Bool { values.isEmpty }

    public init(days: [String: Double] = [:]) { values = Self.cleaned(days) }

    public func merging(_ other: Self) -> Self {
        var result = values
        for (day, seconds) in other.values {
            result[day] = min(Self.maximumDailySeconds, result[day, default: 0] + seconds)
        }
        return Self(days: result)
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static let maximumDailySeconds = 48.0 * 60 * 60
    private static func cleaned(_ source: [String: Double]) -> [String: Double] {
        source.filter { day, seconds in validDay(day) && seconds.isFinite && seconds > 0 && seconds <= maximumDailySeconds }
    }
    private static func validDay(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == parts[0] && actual.month == parts[1] && actual.day == parts[2]
    }

    private enum CodingKeys: String, CodingKey { case days }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(days: try container.decodeIfPresent([String: Double].self, forKey: .days) ?? [:])
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .days)
    }

    fileprivate mutating func addInterval(from start: Date, to end: Date, calendar: Calendar) {
        var cursor = start
        while cursor < end {
            let midnight = calendar.startOfDay(for: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight), next > cursor else { return }
            let boundary = min(end, next)
            let key = Self.dayKey(for: cursor, calendar: calendar)
            values[key] = min(Self.maximumDailySeconds, values[key, default: 0] + boundary.timeIntervalSince(cursor))
            cursor = boundary
        }
    }
}

/// The one-second player sampler submits only normal forward playback; gaps and seeks establish a new baseline.
public struct PlaybackWatchSampler: Sendable {
    private struct Sample: Sendable {
        let identity: String
        let playing: Bool
        let position: Double
        let speed: Double
        let date: Date
        let uptime: TimeInterval
    }
    private var previous: Sample?
    private var pending: [String: PlaybackWatchActivity] = [:]
    public init() {}

    public mutating func sample(identity: String?, playing: Bool, position: Double, speed: Double = 1,
                                now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                calendar: Calendar = .current) {
        guard let identity, !identity.isEmpty, position.isFinite, position >= 0,
              uptime.isFinite, now.timeIntervalSince1970.isFinite, speed.isFinite, speed > 0, speed <= 8 else {
            previous = nil
            return
        }
        let current = Sample(identity: identity, playing: playing, position: position, speed: speed, date: now, uptime: uptime)
        defer { previous = current }
        guard let previous, previous.identity == identity, previous.playing, playing else { return }
        let elapsed = uptime - previous.uptime
        let wallElapsed = now.timeIntervalSince(previous.date)
        let advanced = position - previous.position
        guard elapsed > 0, elapsed <= 3, wallElapsed > 0, abs(wallElapsed - elapsed) < 0.5,
              advanced > 0, advanced <= elapsed * max(previous.speed, speed) * 1.35 + 0.5 else { return }
        var activity = pending[identity] ?? PlaybackWatchActivity()
        activity.addInterval(from: previous.date, to: now, calendar: calendar)
        pending[identity] = activity
    }

    public mutating func drain(identity: String) -> PlaybackWatchActivity {
        pending.removeValue(forKey: identity) ?? PlaybackWatchActivity()
    }
    public mutating func interrupt() { previous = nil }
    public mutating func reset() { previous = nil; pending.removeAll() }
}
