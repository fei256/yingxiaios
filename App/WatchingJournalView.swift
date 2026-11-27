import SwiftUI
import Perception
import TVCore

#if os(iOS)
struct WatchingJournalView: View {
    @Environment(Store.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isLocalPageActive) private var pageActive
    @Environment(\.openHistoryDetails) private var openDetails
    @Environment(\.scenePhase) private var scenePhase
    @State private var schedule = WatchingJournalSchedule()
    @State private var selectedDate = Date()
    @State private var section: JournalLibrarySection = .history
    @State private var period: JournalStatisticsPeriod = .week
    @State private var editing = false
    @State private var confirmsClear = false
    @State private var calendarShown = false
    @State private var refresh = 0
    @State private var today = Date()

    private var entries: [PlaybackHistoryEntry] { store.visibleHistory }
    private var works: [JournalTrackedWork] { JournalTrackedWork.history(entries) }
    private var favorites: [JournalTrackedWork] {
        let indexed = Dictionary(uniqueKeysWithValues: works.map { ($0.catalogKey, $0) })
        return store.favorites.titleVideos.map { JournalTrackedWork.favorite($0, indexed: indexed, scope: store.historyScope) }
            .filter { $0.latest != nil || store.historyClient($0.routeEntry) != nil }
    }
    private var watching: [JournalTrackedWork] {
        works.filter { work in
            guard let entry = work.latest else { return false }
            if !entry.completed { return true }
            return schedule.details[work.id]?.mediaType == .tv && schedule.progress(work).fraction < 1
        }
    }
    private var later: [JournalTrackedWork] { favorites.filter { $0.latest == nil } }
    private var tracked: [JournalTrackedWork] {
        var seen = Set<String>()
        return (works + later).filter { seen.insert($0.id).inserted }
    }
    private var libraryWorks: [JournalTrackedWork] {
        switch section {
        case .history: works
        case .watching: watching
        case .favorites: favorites
        case .later: later
        }
    }
    private var canInteract: Bool { isEnabled && pageActive && store.section == .history }
    private var requestKey: String {
        "\(pageActive)|\(store.historyScope ?? "")|\(refresh)|" + tracked.map(\.id).joined(separator: "|")
    }
    private var activity: [String: Double] {
        entries.reduce(into: [:]) { result, entry in
            for (day, seconds) in entry.watchActivity?.days ?? [:] where seconds.isFinite && seconds > 0 {
                result[day, default: 0] += seconds
            }
        }
    }
    private var statisticsInterval: DateInterval {
        period.interval(containing: today) ?? DateInterval(start: today, duration: 86_400)
    }
    private var statisticDays: [(date: Date, seconds: Double)] {
        let interval = statisticsInterval
        let secondsByDay = activity
        var result: [(date: Date, seconds: Double)] = []
        var day = interval.start
        while day < interval.end, result.count < 32 {
            result.append((day, secondsByDay[JournalCalendarDates.key(day), default: 0]))
            guard let next = JournalCalendarDates.calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }
    private var statisticsEntries: [PlaybackHistoryEntry] {
        let days = Set(statisticDays.map { JournalCalendarDates.key($0.date) })
        return entries.filter { entry in
            entry.watchActivity?.days.contains { days.contains($0.key) && $0.value > 0 } ?? false
        }
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if let error = store.playbackHistory.persistenceError {
                            StatusNotice(text: L10n.text("Unable to save playback history: %@", error))
                        }
                        JournalOverviewCard(seconds: activity.values.reduce(0, +), days: activity.count,
                                            counts: [.history: works.count, .favorites: favorites.count,
                                                     .later: later.count, .watching: watching.count], section: $section)
                        calendarPanel
                        JournalStatisticsCard(seconds: statisticDays.reduce(0) { $0 + $1.seconds },
                                              range: JournalCalendarDates.range(statisticsInterval), bars: statisticDays,
                                              shows: JournalTrackedWork.history(statisticsEntries).count,
                                              episodes: statisticsEntries.count, period: $period)
                        libraryPanel
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 108)
                    .frame(maxWidth: 900).frame(maxWidth: .infinity)
                }
            }
            .scrollIndicators(.hidden)
            .libraryBackdrop()
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .disabled(!canInteract)
            .task(id: requestKey) {
                guard pageActive else { return }
                today = Date()
                await schedule.load(tracked)
            }
            .appOnChange(of: scenePhase) { _, phase in
                if phase == .active { today = Date(); refresh += 1 }
            }
            .onReceive(NotificationCenter.default.publisher(for: TMDBMatchStore.choiceChanged)) { _ in refresh += 1 }
            .onReceive(NotificationCenter.default.publisher(for: TMDBServiceSettings.changed)) { _ in refresh += 1 }
            .confirmationDialog("清空当前显示的观看记录？", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("清空观看记录", role: .destructive) {
                    guard canInteract else { return }
                    store.playbackHistory.remove(Set(entries.map(\.id)))
                }
                Button("取消", role: .cancel) {}
            }
            .localGlassDialog(isPresented: $calendarShown, title: "追剧日历", maxWidth: 520, maxHeight: 580, layout: .centered) {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: 16) {
                        DatePicker("选择日期", selection: $selectedDate, displayedComponents: .date)
                            .datePickerStyle(.graphical).tint(JournalPalette.purple)
                            .accessibilityIdentifier("journal.calendar.picker")
                        Button("查看这一天") { calendarShown = false }
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            .buttonStyle(.borderedProminent).tint(JournalPalette.purple)
                    }.padding(12).localDialogContentHeight()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("我的").font(.system(size: 28, weight: .bold))
                Text("你的私人观影手账").font(.subheadline).foregroundStyle(.white.opacity(0.53))
            }
            Spacer()
            Menu {
                Button(editing ? "完成编辑" : "编辑观看记录", systemImage: editing ? "checkmark" : "slider.horizontal.3") { editing.toggle() }
                Button("清空观看记录", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(entries.isEmpty)
            } label: {
                Label(editing ? "完成" : "编辑", systemImage: "slider.horizontal.3").font(.subheadline)
                    .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                    .background(.black.opacity(0.16), in: Capsule())
            }.accessibilityIdentifier("journal.edit")
        }
    }

    private var calendarPanel: some View {
        let episodes = schedule.episodes(tracked, on: JournalCalendarDates.key(selectedDate))
        let marked = Set(schedule.episodes(tracked).map(\.date))
        return JournalPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("追剧日历").font(.headline)
                    if schedule.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { calendarShown = true } label: {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 21))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("展开追剧日历").accessibilityIdentifier("journal.calendar.expand")
                }
                JournalWeekStrip(selection: $selectedDate, markedDays: marked, now: today)
                if !episodes.isEmpty {
                    ForEach(episodes) { episode in
                        WithPerceptionTracking {
                            showRow(episode.work, airing: episode)
                            if episode.id != episodes.last?.id { Divider().overlay(.white.opacity(0.04)) }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(schedule.loading ? "正在获取剧集排期…" : "这一天暂无已知更新", systemImage: "calendar")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                        Text("已匹配 TMDB 的在看和待看剧集会显示在这里。")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                    }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                }
                if !schedule.failed.isEmpty {
                    HStack {
                        Text("部分排期暂时无法刷新").font(.caption).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Button("重试") { refresh += 1 }.font(.caption).frame(minHeight: 44)
                    }
                }
                if !tracked.isEmpty, tracked.contains(where: { schedule.details[$0.id] == nil }) {
                    Text("未匹配或未公布日期的剧集仍保留在下方，打开详情匹配后即可查看排期。")
                        .font(.caption2).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private var libraryPanel: some View {
        let libraryWorks = self.libraryWorks
        return JournalPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(section == .history ? "最近观看" : section.title).font(.headline)
                    Spacer()
                    Text("\(libraryWorks.count) 部").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                if libraryWorks.isEmpty {
                    Text(section == .later ? "收藏尚未开始观看的作品，会出现在待看中。" : "这里还没有记录，开始观看后会自动保存进度。")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.6)).padding(.vertical, 14)
                } else {
                    ForEach(libraryWorks) { work in
                        WithPerceptionTracking {
                            showRow(work)
                            if work.id != libraryWorks.last?.id { Divider().overlay(.white.opacity(0.04)) }
                        }
                    }
                }
                if entries.contains(where: { $0.watchActivity == nil }) {
                    Text("已有观看进度已保留，旧记录不补算观看时长。").font(.caption2).foregroundStyle(.white.opacity(0.43))
                }
            }
        }
    }

    private func showRow(_ work: JournalTrackedWork, airing: JournalScheduledEpisode? = nil) -> some View {
        let details = schedule.details[work.id]
        let progress = schedule.progress(work)
        return HStack(alignment: .top, spacing: 14) {
            Button { reveal(work) } label: {
                Group {
                    if let entry = work.latest { HistoryPoster(entry: entry) }
                    else { PosterImage(url: work.poster, headers: work.posterHeaders) }
                }.frame(width: 62, height: 92).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看 \(work.title) 详情")
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    Button { reveal(work) } label: {
                        Text(work.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("journal.work.\(work.videoID)")
                    if editing {
                        Button(role: .destructive) { remove(work) } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 19)).foregroundStyle(JournalPalette.rose)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("移除 \(work.title)")
                    } else if work.latest != nil {
                        Button { resume(work) } label: {
                            Image(systemName: "play.fill").font(.system(size: 16))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("继续播放 \(work.title)")
                            .accessibilityIdentifier("journal.resume.\(work.videoID)")
                    }
                }
                Text([details?.year.map(String.init) ?? work.year, details?.genres.prefix(3).joined(separator: " "),
                      SourceLabel(work.sourceName).text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  "))
                    .font(.caption).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                if let airing {
                    Text(airing.title + " 更新").font(.caption.weight(.medium)).foregroundStyle(JournalPalette.purple)
                }
                Text(progress.label).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                JournalProgress(value: progress.fraction)
            }
        }.padding(.vertical, 4)
    }

    private func resume(_ work: JournalTrackedWork) {
        guard canInteract, let entry = work.latest else { return }
        store.resume(entry)
    }
    private func reveal(_ work: JournalTrackedWork) {
        guard canInteract else { return }
        if let client = store.historyClient(work.routeEntry), let openDetails {
            openDetails(Route { AnyView(VideoDetailView(video: work.routeEntry.listVideo, client: client)) })
        } else if work.latest != nil { resume(work) }
        else { store.searchVideos(work.title) }
    }
    private func remove(_ work: JournalTrackedWork) {
        guard canInteract else { return }
        if section == .favorites || section == .later, let saved = work.saved { store.favorites.removeTitle(saved) }
        else { store.playbackHistory.remove(Set(work.entries.map(\.id))) }
    }
}
#endif
