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
}

enum JournalPalette {
    static let purple = Color(red: 0.50, green: 0.40, blue: 0.96)
    static let rose = Color(red: 0.91, green: 0.16, blue: 0.31)
}

struct JournalPanel<Content: View>: View {
    var overview = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
                if overview {
                    shape.fill(LinearGradient(colors: [Color(red: 0.15, green: 0.17, blue: 0.27),
                                                       Color(red: 0.09, green: 0.11, blue: 0.14),
                                                       Color(red: 0.14, green: 0.18, blue: 0.21)],
                                              startPoint: .leading, endPoint: .trailing))
                } else { shape.fill(Color(red: 0.075, green: 0.091, blue: 0.12).opacity(0.86)) }
            }
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
    var body: some View {
        JournalPanel(overview: true) {
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
                        NavigationLink(value: value) {
                            VStack(spacing: 8) {
                                Image(systemName: value.symbol).font(.system(size: 23, weight: .medium))
                                    .foregroundStyle(value == .favorites ? JournalPalette.rose : JournalPalette.purple)
                                Text(value.title).font(.subheadline.weight(.medium))
                                Text("\(counts[value, default: 0])").font(.caption).foregroundStyle(.white.opacity(0.57))
                            }.frame(maxWidth: .infinity, minHeight: 82).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("journal.section.\(value.rawValue)")
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
