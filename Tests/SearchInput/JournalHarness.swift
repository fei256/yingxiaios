import SwiftUI

/// Native interaction and layout checks use the production journal components with fixed data.
struct JournalHarness: View {
    @State private var selectedDate = JournalCalendarDates.date("2026-11-20")!
    private let today = JournalCalendarDates.date("2026-11-20")!
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("我的").font(.system(size: 28, weight: .bold))
                Text("你的私人观影手账").foregroundStyle(.white.opacity(0.55)).font(.subheadline)
                Text(JournalCalendarDates.key(selectedDate))
                    .font(.caption2).accessibilityIdentifier("journal.selection")
                JournalOverviewCard(seconds: 1_140, days: 2,
                                    counts: [.history: 5, .favorites: 0, .later: 0, .watching: 5])
                JournalPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("追剧日历").font(.headline)
                        JournalWeekStrip(selection: $selectedDate, markedDays: ["2026-11-21"], now: today)
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(colors: [.orange.opacity(0.7), .brown, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay { Image(systemName: "film").font(.title).foregroundStyle(.white.opacity(0.65)) }
                                .frame(width: 62, height: 92)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("凡人修仙传").font(.headline)
                                Text("2020  动画  动作冒险").font(.caption).foregroundStyle(.white.opacity(0.50))
                                Text("第 1 季 · 第 201/210 集").font(.caption)
                                JournalProgress(value: 201.0 / 210.0)
                            }
                        }
                    }
                }
            }.padding(20).padding(.bottom, 30).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.libraryBackdrop()
        .navigationBarHidden(true)
        .navigationDestination(for: JournalLibrarySection.self) { section in
            Text(section.title).accessibilityIdentifier("journal.list." + section.rawValue)
                .navigationTitle(section.title).navigationBarHidden(false)
        }
    }
}
