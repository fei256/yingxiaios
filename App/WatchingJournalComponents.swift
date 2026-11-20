import SwiftUI

enum JournalLibrarySection: String, CaseIterable, Identifiable {
    case history, favorites, later, watching
    var id: String { rawValue }
    var title: String {
        switch self { case .history: "历史"; case .favorites: "收藏"; case .later: "待看"; case .watching: "在看" }
    }
    var symbol: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .favorites: "bookmark.fill"
        case .later: "film.stack"
        case .watching: "play.circle.fill"
        }
    }
}

enum JournalStatisticsPeriod: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }
    var title: String { switch self { case .today: "今天"; case .week: "本周"; case .month: "本月" } }
    func interval(containing date: Date, calendar: Calendar = JournalCalendarDates.calendar) -> DateInterval? {
        calendar.dateInterval(of: self == .today ? .day : self == .week ? .weekOfYear : .month, for: date)
    }
}

enum JournalCalendarDates {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        value.firstWeekday = 1
        value.minimumDaysInFirstWeek = 1
        return value
    }
    static func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func date(_ key: String) -> Date? {
        guard key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              self.key(date) == key else { return nil }
        return date
    }
    static func week(containing date: Date) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    static func weekday(_ date: Date) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][calendar.component(.weekday, from: date) - 1]
    }
    static func range(_ interval: DateInterval) -> String {
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: interval.start) + " – " + formatter.string(from: end)
    }
}

enum JournalPalette {
    static let purple = Color(red: 0.50, green: 0.40, blue: 0.96)
    static let rose = Color(red: 0.91, green: 0.16, blue: 0.31)
}

struct JournalPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.035, green: 0.050, blue: 0.075).opacity(0.68),
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.035), lineWidth: 1) }
    }
}

struct JournalDuration: View {
    let seconds: Double
    var large = false
    private var minutes: Int { Int(min(Double(Int.max / 120), max(0, seconds.isFinite ? seconds : 0)) / 60) }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(minutes / 60)").font(.system(size: large ? 34 : 28, weight: .medium, design: .rounded))
            Text("小时").font(.caption).foregroundStyle(.white.opacity(0.68))
            Text("\(minutes % 60)").font(.system(size: large ? 34 : 28, weight: .medium, design: .rounded))
            Text("分钟").font(.caption).foregroundStyle(.white.opacity(0.68))
        }.monospacedDigit().accessibilityElement(children: .ignore)
            .accessibilityLabel("\(minutes / 60) 小时 \(minutes % 60) 分钟")
    }
}

struct JournalOverviewCard: View {
    let seconds: Double
    let days: Int
    let counts: [JournalLibrarySection: Int]
    @Binding var section: JournalLibrarySection
    var body: some View {
        JournalPanel {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Label("观影时光", systemImage: "sparkles").font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.76))
                    Spacer()
                    Text("观影 \(days) 天").font(.caption).foregroundStyle(JournalPalette.purple)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(JournalPalette.purple.opacity(0.08), in: Capsule())
                }
                VStack(alignment: .leading, spacing: 8) {
                    JournalDuration(seconds: seconds, large: true).accessibilityIdentifier("journal.total.duration")
                    Text("每一段故事，都在这里留下回响。").font(.subheadline).foregroundStyle(.white.opacity(0.52))
                }
                Divider().overlay(.white.opacity(0.025))
                HStack(spacing: 0) {
                    ForEach(JournalLibrarySection.allCases) { value in
                        Button { section = value } label: {
                            VStack(spacing: 8) {
                                Image(systemName: value.symbol).font(.system(size: 23, weight: .medium))
                                    .foregroundStyle(value == .favorites ? JournalPalette.rose : JournalPalette.purple)
                                Text(value.title).font(.subheadline.weight(.medium))
                                Text("\(counts[value, default: 0])").font(.caption).foregroundStyle(.white.opacity(0.57))
                            }.frame(maxWidth: .infinity, minHeight: 82).contentShape(Rectangle())
                                .background(section == value ? .white.opacity(0.035) : .clear,
                                            in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).accessibilityIdentifier("journal.section.\(value.rawValue)")
                            .accessibilityAddTraits(section == value ? .isSelected : [])
                    }
                }
            }
        }
    }
}

struct JournalWeekStrip: View {
    @Binding var selection: Date
    let markedDays: Set<String>
    var now = Date()
    var body: some View {
        GeometryReader { geometry in
        ScrollView(.horizontal) {
        HStack(spacing: 4) {
            ForEach(JournalCalendarDates.week(containing: selection), id: \.self) { date in
                let picked = JournalCalendarDates.calendar.isDate(date, inSameDayAs: selection)
                let today = JournalCalendarDates.calendar.isDate(date, inSameDayAs: now)
                Button { selection = date } label: {
                    VStack(spacing: 5) {
                        Text("\(JournalCalendarDates.calendar.component(.day, from: date))")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(JournalCalendarDates.weekday(date)).font(.caption)
                            .foregroundStyle(today ? JournalPalette.rose : .white.opacity(0.58))
                        Circle().fill(markedDays.contains(JournalCalendarDates.key(date)) ? JournalPalette.purple : .clear)
                            .frame(width: 4, height: 4).accessibilityHidden(true)
                    }.frame(width: max(44, (geometry.size.width - 24) / 7), height: 68).contentShape(Rectangle())
                        .background(picked ? Color.black.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(picked ? .white.opacity(0.065) : .clear, lineWidth: 1) }
                }.buttonStyle(.plain).accessibilityIdentifier("journal.day.\(JournalCalendarDates.key(date))")
                    .accessibilityLabel("\(JournalCalendarDates.key(date))，\(JournalCalendarDates.weekday(date))")
                    .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        }.scrollIndicators(.hidden)
        }.frame(height: 68)
    }
}

struct JournalProgress: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.14))
                .overlay(alignment: .leading) {
                    Capsule().fill(JournalPalette.rose)
                        .frame(width: geometry.size.width * min(1, max(0, value.isFinite ? value : 0)))
                }
        }.frame(height: 3).accessibilityHidden(true)
    }
}

struct JournalStatisticsCard: View {
    let seconds: Double
    let range: String
    let bars: [(date: Date, seconds: Double)]
    let shows: Int
    let episodes: Int
    @Binding var period: JournalStatisticsPeriod
    var body: some View {
        JournalPanel {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack { Text("观看统计").font(.headline); Spacer(); periodPicker }
                    VStack(alignment: .leading, spacing: 12) { Text("观看统计").font(.headline); periodPicker }
                }
                Text(range).font(.caption).foregroundStyle(.white.opacity(0.50))
                JournalDuration(seconds: seconds).accessibilityIdentifier("journal.statistics.duration")
                HStack(spacing: 16) {
                    Label("\(shows) 部作品", systemImage: "film")
                    Label("\(episodes) 集 / 部", systemImage: "play.rectangle")
                }.font(.caption).foregroundStyle(.white.opacity(0.62))
                if !bars.isEmpty {
                    let highest = max(60, bars.map(\.seconds).max() ?? 0)
                    HStack(alignment: .bottom, spacing: bars.count > 10 ? 3 : 8) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                            VStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(JournalPalette.purple.opacity(bar.seconds > 0 ? 0.70 : 0.10))
                                    .frame(height: max(3, 48 * min(1, max(0, bar.seconds / highest))))
                                if bars.count <= 7 {
                                    Text("\(JournalCalendarDates.calendar.component(.day, from: bar.date))")
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                                }
                            }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(JournalCalendarDates.key(bar.date))，\(Int(max(0, bar.seconds) / 60)) 分钟")
                        }
                    }.frame(height: bars.count > 7 ? 48 : 68, alignment: .bottom)
                }
                Text("观看时长从此版本开始累计，暂停、缓冲和跳转进度不计入。")
                    .font(.caption2).foregroundStyle(.white.opacity(0.46))
            }
        }
    }
    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(JournalStatisticsPeriod.allCases) { value in
                Button { period = value } label: {
                    Text(value.title).font(.caption.weight(period == value ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(period == value ? 0.96 : 0.48))
                        .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                        .background(period == value ? .white.opacity(0.045) : .clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("journal.statistics.\(value.rawValue)")
                    .accessibilityAddTraits(period == value ? .isSelected : [])
            }
        }.padding(3).background(.white.opacity(0.025), in: Capsule())
    }
}
