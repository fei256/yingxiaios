import Foundation
import Perception
import TVCore

struct JournalTrackedWork: Identifiable, Sendable {
    let id: String
    let entries: [PlaybackHistoryEntry]
    let saved: FavoriteVideo?
    let scope: String?
    var latest: PlaybackHistoryEntry? { entries.first }
    var title: String { latest?.context.displayTitle ?? saved?.videoName ?? "" }
    var origin: URL { latest?.context.origin ?? saved!.origin }
    var sourceKey: String { latest?.context.sourceKey ?? saved!.sourceKey }
    var sourceName: String { latest?.context.sourceName ?? saved?.sourceName ?? "" }
    var videoID: String { latest?.context.videoID ?? saved!.videoID }
    var poster: URL? { latest?.context.poster ?? saved?.poster }
    var posterHeaders: [String: String] { latest?.context.posterHeaders ?? saved?.posterHeaders ?? [:] }
    var year: String? { latest?.context.year ?? saved?.year }
    var catalogKey: String { Self.catalogKey(origin: origin, source: sourceKey, video: videoID) }
    var matchKey: String {
        TMDBMatchStore.key(source: PosterPresentation.matchSourceIdentity(origin: origin, sourceKey: sourceKey), video: videoID)
    }
    var routeEntry: PlaybackHistoryEntry {
        if let latest { return latest }
        var context = PlaybackHistoryContext(origin: origin, sourceKey: sourceKey, sourceName: sourceName,
                                             videoID: videoID, videoName: title, poster: poster,
                                             episodeID: "", episodeName: "", episodeFlag: "")
        context.year = year
        context.posterHeaders = posterHeaders.isEmpty ? nil : posterHeaders
        context.historyScope = scope ?? ""
        return PlaybackHistoryEntry(context: context, position: 0, duration: 0, updatedAt: .distantPast)
    }
    static func catalogKey(origin: URL, source: String, video: String) -> String {
        EpisodeSkipSettings.scope(origin: PlaybackHistoryContext.sourceIdentity(origin), source: source, video: video)
    }
    static func history(_ entries: [PlaybackHistoryEntry]) -> [Self] {
        let sorted = entries.sorted { $0.updatedAt > $1.updatedAt }
        var groups: [String: [PlaybackHistoryEntry]] = [:]
        var order: [String] = []
        for entry in sorted {
            let key = catalogKey(origin: entry.context.origin, source: entry.context.sourceKey, video: entry.context.videoID)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { Self(id: $0, entries: groups[$0] ?? [], saved: nil, scope: groups[$0]?.first?.context.libraryScope) }
    }
    static func favorite(_ saved: FavoriteVideo, history: [Self], scope: String?) -> Self {
        let key = catalogKey(origin: saved.origin, source: saved.sourceKey, video: saved.videoID)
        return Self(id: key, entries: history.first { $0.catalogKey == key }?.entries ?? [], saved: saved, scope: scope)
    }
}

struct JournalScheduledEpisode: Identifiable {
    let work: JournalTrackedWork
    let date: String
    let season: Int
    let number: Int
    var id: String { "\(work.id)|\(date)|\(season)|\(number)" }
    var title: String { "第 \(season) 季 · 第 \(number) 集" }
}

@MainActor @Perceptible final class WatchingJournalSchedule {
    private(set) var details: [String: TMDBMatch.Details] = [:]
    private(set) var matches: [String: TMDBMatch.Match] = [:]
    private(set) var loading = false
    private(set) var failed = Set<String>()
    @PerceptionIgnored private var loadID = UUID()

    private struct Request: Sendable {
        let key: String
        let matchKey: String
        let type: TMDBMatch.MediaType
        let id: Int
        let season: Int?
    }
    private struct Response: Sendable {
        let request: Request
        let details: TMDBMatch.Details?
    }

    /// Only confirmed source/video matches supply airing dates. A similar title cannot silently
    /// become a different show, and a user's "none of these" choice is respected.
    func load(_ works: [JournalTrackedWork]) async {
        let active = UUID()
        loadID = active
        loading = true
        failed.removeAll()
        defer { if loadID == active { loading = false } }
        let present = Set(works.map(\.id))
        details = details.filter { present.contains($0.key) }
        matches = matches.filter { present.contains($0.key) }
        var requests: [Request] = []
        for work in works {
            guard !Task.isCancelled else { return }
            let key = work.matchKey
            let choice = await TMDBMatchStore.shared.choice(for: key)
            if case .none? = choice { details[work.id] = nil; matches[work.id] = nil; continue }
            let answer = await TMDBMatchStore.shared.calendarMatch(for: key)
            guard !Task.isCancelled else { return }
            if let answer, answer.status == .matched, let cached = answer.details {
                details[work.id] = cached
                matches[work.id] = answer.match
            } else {
                details[work.id] = nil
                matches[work.id] = nil
            }
            if case .work(let type, let id, let season)? = choice {
                requests.append(Request(key: work.id, matchKey: key, type: type, id: id, season: season))
            } else if let match = answer?.match, answer?.status == .matched {
                requests.append(Request(key: work.id, matchKey: key, type: match.mediaType, id: match.id, season: match.season))
            }
        }
        await withTaskGroup(of: Response.self) { group in
            var remaining = requests.makeIterator()
            func enqueue(_ request: Request) {
                group.addTask {
                    let value = try? await TMDBMatch.details(request.type, id: request.id, season: request.season)
                    return Response(request: request, details: value)
                }
            }
            for _ in 0..<4 { if let request = remaining.next() { enqueue(request) } }
            for await response in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let value = response.details {
                    details[response.request.key] = value
                    _ = await TMDBMatchStore.shared.update(value, for: response.request.matchKey)
                } else { failed.insert(response.request.key) }
                if let request = remaining.next() { enqueue(request) }
            }
        }
    }

    func episodes(_ works: [JournalTrackedWork], on date: String? = nil) -> [JournalScheduledEpisode] {
        var seen = Set<String>()
        var result: [JournalScheduledEpisode] = []
        for work in works {
            guard let details = details[work.id], details.mediaType == .tv else { continue }
            func append(day: String, season: Int, number: Int) {
                guard (date == nil || date == day), JournalCalendarDates.date(day) != nil,
                      season > 0, number > 0,
                      seen.insert("\(details.id)|\(day)|\(season)|\(number)").inserted else { return }
                result.append(JournalScheduledEpisode(work: work, date: day, season: season, number: number))
            }
            if let season = details.season {
                for episode in season.episodes {
                    if let day = episode.airDate { append(day: day, season: season.number, number: episode.number) }
                }
            }
            if let next = details.nextEpisode { append(day: next.date, season: next.season, number: next.number) }
        }
        return result.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.work.title != $1.work.title { return $0.work.title.localizedStandardCompare($1.work.title) == .orderedAscending }
            return $0.number < $1.number
        }
    }

    func progress(_ work: JournalTrackedWork) -> (label: String, fraction: Double) {
        guard let entry = work.latest else { return ("尚未开始观看", 0) }
        if entry.context.readingProgress != nil { return (HistoryFormat.status(entry), entry.progress) }
        let parsed = LocalDetailEpisodeNumbers.numbers(entry.context.episodeName)
        if let detail = details[work.id], detail.mediaType == .tv, let episode = parsed.episode {
            let season = parsed.season ?? matches[work.id]?.season ?? detail.season?.number ?? 1
            let count = detail.seasons.first { $0.number == season }?.episodeCount ?? detail.season?.episodes.count ?? 0
            if matches[work.id]?.numbering != .absolute, count > 0, episode > 0, episode <= count {
                return ("第 \(season) 季 · 第 \(episode)/\(count) 集", (Double(episode - 1) + entry.progress) / Double(count))
            }
        }
        let episode = EpisodeLabels.historyLabel(entry.context.episodeName, showsDetails: false)
        return ([episode, HistoryFormat.status(entry)].filter { !$0.isEmpty }.joined(separator: " · "), entry.progress)
    }
}
