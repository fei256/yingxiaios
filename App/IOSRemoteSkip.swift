#if os(iOS)
import Foundation
import Perception
import TVCore

/// Optional metadata/network work never blocks picture readiness or the local skip clock.
@MainActor @Perceptible final class NativeRemoteSkip {
    private(set) var segments: [RemoteEpisodeSkipSegment] = []
    private(set) var status = ""
    private(set) var notice: PlayerNotice?
    struct Action: Sendable {
        let id: UUID
        let target: Double
        let kind: String
    }
    @PerceptionIgnored private var pendingAction: UUID?
    @PerceptionIgnored private var panelRequested = false
    @PerceptionIgnored private var channel: Channel?
    @PerceptionIgnored private var live = false
    @PerceptionIgnored private var task: Task<Void, Never>?
    @PerceptionIgnored private var generation = UUID()
    @PerceptionIgnored private var input: Input?
    @PerceptionIgnored private var remote: [RemoteEpisodeSkipSegment] = []
    @PerceptionIgnored private var pass = RemoteEpisodeSkipPass()
    @PerceptionIgnored private var retryAt = Date.distantPast
    @PerceptionIgnored private var attempts = 0
    private struct CachedPlan {
        let address: URL
        let episode: String
        let playlist: Int?
        let duration: Double
        let expires: TimeInterval
        let segments: [RemoteEpisodeSkipSegment]
    }
    // Only reuse a verified plan for the same input and episode. Provider payloads
    // prefetched for another input are validated against its actual duration.
    @PerceptionIgnored private var cache: [CachedPlan] = []
    private struct Input: Equatable {
        let session: String
        let settings: EpisodeSkipSettings
        let duration: Double
        let chapters: [RemoteEpisodeSkipChapter]
    }
    private func setStatus(_ message: String, kind: PlayerNotice.Kind = .information) {
        guard status != message else { return }
        status = message
        if kind == .information, notice?.kind == .success,
           notice?.isVisible(at: ProcessInfo.processInfo.systemUptime) == true { return }
        notice = message.isEmpty ? nil : PlayerNotice(message: message, kind: kind)
    }

    func begin(channel: Channel, isLive: Bool) {
        let sameInput = self.channel?.id == channel.id && self.channel?.historyContext?.id == channel.historyContext?.id &&
            self.channel?.playback?.discPlaylist == channel.playback?.discPlaylist
        let previousPass = pass
        stop(); self.channel = channel; live = isLive
        if sameInput { pass = previousPass }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; input = nil
        remote = []; segments = []; status = ""; notice = nil; pendingAction = nil; panelRequested = false; channel = nil
        pass = RemoteEpisodeSkipPass(); attempts = 0; retryAt = .distantPast
    }
    var matching: Bool { task != nil }
    func requestMatch(_ visible: Bool = true) { panelRequested = visible }
    func settingsChanged() {
        generation = UUID(); task?.cancel(); task = nil; input = nil
        pendingAction = nil; segments = []; remote = []
        pass = RemoteEpisodeSkipPass(); attempts = 0; retryAt = .distantPast
    }
    func refreshLocal(settings: EpisodeSkipSettings, duration: Double, chapters: [KSPlaybackChapter], sessionID: String) {
        guard duration.isFinite, duration > 0, !live else { return }
        let chapters = chapters.map { RemoteEpisodeSkipChapter(time: $0.start, title: $0.title, end: $0.end) }
        let next = Input(session: sessionID, settings: settings, duration: duration.rounded(), chapters: chapters)
        guard input != next else { return }
        generation = UUID(); task?.cancel(); task = nil; input = next
        attempts = 0; retryAt = .distantPast
        remote = channel.flatMap { current in
            cache.last { matches($0, channel: current, duration: duration) }?.segments
        } ?? []
        let local = RemoteEpisodeSkipPlan.local(settings: settings, duration: duration, chapters: chapters)
        segments = RemoteEpisodeSkipPlan.merging(local: local, remote: remote, duration: duration)
    }
    private func matches(_ plan: CachedPlan, channel: Channel, duration: Double) -> Bool {
        plan.expires > ProcessInfo.processInfo.systemUptime && plan.address == channel.url &&
            plan.episode == channel.historyContext?.id && plan.playlist == channel.playback?.discPlaylist &&
            plan.duration == duration.rounded()
    }
    private func remember(_ segments: [RemoteEpisodeSkipSegment], channel: Channel, duration: Double) {
        guard let episode = channel.historyContext?.id, !segments.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = cache.last { matches($0, channel: channel, duration: duration) }?.segments ?? []
        let previousKinds = Set(previous.map(\.kind))
        let combined = RemoteEpisodeSkipPlan.merging(local: previous, remote: segments.filter { !previousKinds.contains($0.kind) }, duration: duration)
        cache = cache.filter { $0.expires > now && !matches($0, channel: channel, duration: duration) }
        if cache.count >= 16 { cache.removeFirst() }
        cache.append(CachedPlan(address: channel.url, episode: episode, playlist: channel.playback?.discPlaylist,
                                duration: duration.rounded(), expires: now + 3600, segments: combined))
    }
    func tick(settings: EpisodeSkipSettings, duration: Double, chapters: [KSPlaybackChapter], sessionID: String, ready: Bool, allowAutomatic: Bool) {
        guard duration.isFinite, duration > 0, !live else { return }
        refreshLocal(settings: settings, duration: duration, chapters: chapters, sessionID: sessionID)
        let local = segments.filter { $0.source == "手动" || $0.source == "章节" }
        guard settings.enabled || panelRequested else { setStatus("自动跳过已关闭"); return }
        guard !Set(local.map(\.kind)).isSuperset(of: ["opening", "ending"]) else { setStatus("已采用手动或章节片头片尾时间"); return }
        guard !Set(segments.map(\.kind)).isSuperset(of: ["opening", "ending"]) else { return }
        guard allowAutomatic || panelRequested, ready, !sessionID.isEmpty, task == nil, attempts < 2, Date() >= retryAt else { return }
        guard let context = channel?.historyContext, !TMDBMatch.skipsSource(key: context.sourceKey, api: "") else {
            setStatus(local.isEmpty ? "尚未识别作品，可手动记录片头片尾" : "已采用章节时间"); return
        }
        let active = generation
        attempts += 1
        setStatus("正在匹配片头片尾")
        task = Task { [weak self] in
            guard let self else { return }
            defer { if active == self.generation { self.task = nil } }
            do {
                guard let identity = try await Self.identity(context) else {
                    guard active == self.generation, !Task.isCancelled else { return }
                    self.setStatus("作品或季集不明确，可手动记录片头片尾")
                    self.attempts = 2; return
                }
                guard active == self.generation, !Task.isCancelled else { return }
                let params: [String: JSONValue] = ["sessionId": .string(sessionID), "mediaVersion": .number(0),
                    "duration": .number(duration), "identity": .object(identity.identity), "metadata": .object(identity.metadata),
                    "preferences": .object(["openingOverride": .number(settings.introEnd), "endingOverride": .number(settings.outroLength)]),
                    "chapters": .array((self.input?.chapters ?? []).map { chapter in
                        var row: [String: JSONValue] = ["time": .number(chapter.time), "title": .string(chapter.title)]
                        if let end = chapter.end { row["end"] = .number(end) }; return .object(row)
                    })]
                // The skip provider receives public IDs only; playback URLs, cookies and configured API keys stay local.
                let providers = identity.identity["mediaType"] != .string("tv") || identity.metadata["imdbId"] == nil ? ["theintrodb"] : ["theintrodb", "introdb"]
                var retryable = false
                var message = ""
                await withTaskGroup(of: JSONValue?.self) { group in
                    for provider in providers {
                        var request = params
                        request["provider"] = .string(provider)
                        group.addTask { [request] in
                            try? await MobileMediaServices.call("intro.plan", request)
                        }
                    }
                    for await result in group {
                        guard active == self.generation, !Task.isCancelled else { group.cancelAll(); return }
                        guard let fields = result?.object,
                              let data = try? JSONEncoder().encode(fields["segments"] ?? .array([])),
                              let received = try? JSONDecoder().decode([RemoteEpisodeSkipSegment].self, from: data) else {
                            retryable = true; continue
                        }
                        retryable = retryable || fields["retryable"] == .bool(true)
                        message = fields["message"]?.string ?? message
                        let previousKinds = Set(self.remote.map(\.kind))
                        self.remote += received.filter {
                            !["手动", "章节"].contains($0.source) && !previousKinds.contains($0.kind) && $0.isValid(duration: duration)
                        }
                        self.segments = RemoteEpisodeSkipPlan.merging(local: local, remote: self.remote, duration: duration)
                        if let channel = self.channel { self.remember(self.remote, channel: channel, duration: duration) }
                    }
                }
                guard active == self.generation, !Task.isCancelled else { return }
                self.setStatus(self.remote.isEmpty ? (message.isEmpty ? "没有匹配的远程片段，已保留本地时间" : message) : "已匹配片头片尾 · " + Array(Set(self.remote.map(\.source))).sorted().joined(separator: " / "))
                if retryable && !Set(self.segments.map(\.kind)).isSuperset(of: ["opening", "ending"]) {
                    self.retryAt = Date().addingTimeInterval(15)
                    self.setStatus(self.attempts < 2 ? "部分在线信息暂不可用，稍后重试；已保留可用时间" : "在线匹配暂不可用，已保留可用时间", kind: .warning)
                } else { self.attempts = 2 }
            } catch {
                guard active == self.generation, !Task.isCancelled else { return }
                self.setStatus("在线匹配暂不可用，已保留本地时间", kind: .warning)
                self.retryAt = Date().addingTimeInterval(15)
            }
        }
    }
    func userSought(to time: Double) { pass.userSought(to: time) }
    func nextAction(time: Double, duration: Double, playing: Bool, enabled: Bool, openingOnly: Bool = false) -> Action? {
        let candidates = openingOnly ? segments.filter { $0.kind == "opening" } : segments
        guard pendingAction == nil,
              let target = pass.target(time: time, duration: duration, playing: playing, enabled: enabled, segments: candidates),
              let segment = candidates.first(where: { time >= $0.start && time < $0.end && abs(min($0.end, duration - 0.05) - target) < 0.1 }) else { return nil }
        let action = Action(id: UUID(), target: target, kind: segment.kind)
        pendingAction = action.id
        return action
    }
    func complete(_ action: Action, succeeded: Bool) {
        guard pendingAction == action.id else { return }
        pendingAction = nil
        let name = action.kind == "ending" ? "片尾" : "片头"
        // Emit only after the actual native seek callback, never when a plan chooses a target.
        notice = PlayerNotice(message: succeeded ? "已自动跳过" + name : "自动跳过" + name + "失败，可手动重试",
                              kind: succeeded ? .success : .warning)
    }

    private struct PrefetchedPlan: Decodable {
        let duration: Double
        let segments: [RemoteEpisodeSkipSegment]
    }
    func prefetch(_ channel: Channel) async {
        guard let context = channel.historyContext, !TMDBMatch.skipsSource(key: context.sourceKey, api: ""),
              let match = try? await Self.identity(context), !Task.isCancelled else { return }
        let params: [String: JSONValue] = ["identity": .object(match.identity), "metadata": .object(match.metadata)]
        guard let result = try? await MobileMediaServices.call("intro.prefetch", params), !Task.isCancelled,
              let plans = result.object?["plans"], let data = try? JSONEncoder().encode(plans),
              let records = try? JSONDecoder().decode([PrefetchedPlan].self, from: data) else { return }
        for record in records {
            remember(record.segments.filter { $0.isValid(duration: record.duration) }, channel: channel, duration: record.duration)
        }
    }
    private static func identity(_ context: PlaybackHistoryContext) async throws -> (identity: [String: JSONValue], metadata: [String: JSONValue])? {
        let lookup = TMDBLookup()
        let key = TMDBMatchStore.key(source: context.sourceKey, video: context.videoID)
        if !(await lookup.prepare(key: key)) {
            let video = Video(id: context.videoID, name: context.videoName, year: context.year,
                episodes: [Episode(id: context.episodeID, name: context.episodeName, address: "", flag: context.episodeFlag)])
            // Omit SourceRef: this is an identity lookup, not a submission of a source/URL association.
            await lookup.run(key: key, request: TMDBMatch.Request(video: video))
        }
        try Task.checkCancellation()
        if lookup.phase == .failed { throw TVError.unsupported("作品信息暂不可用") }
        guard let details = lookup.details, details.id > 0, lookup.phase == .matched,
              !LocalDetailEpisodeNumbers.isExtra(context.episodeName) else { return nil }
        var result: [String: JSONValue] = ["tmdbId": .number(Double(details.id)), "mediaType": .string(details.mediaType.rawValue)]
        if details.mediaType == .tv {
            let explicit = LocalDetailEpisodeNumbers.numbers(context.episodeName)
            let inferred = LocalDetailEpisodeNumbers.numbers(context.episodeFlag + " " + context.videoName)
            let seasons = details.seasons.filter { $0.number > 0 }
            let selected = lookup.chosen ? details.season?.number : nil
            let season = selected ?? explicit.season ?? inferred.season ?? (seasons.count == 1 && seasons[0].number == 1 ? 1 : nil)
            guard let season, season > 0, explicit.season == nil || explicit.season == season,
                  let known = seasons.first(where: { $0.number == season }), let rawEpisode = explicit.episode else { return nil }
            var episode = rawEpisode + lookup.offset
            if lookup.numbering == .absolute {
                let previous = seasons.filter { $0.number < season }
                guard previous.count == season - 1, previous.allSatisfy({ $0.episodeCount > 0 }) else { return nil }
                episode -= previous.reduce(0) { $0 + $1.episodeCount }
            }
            guard episode > 0, known.episodeCount == 0 || episode <= known.episodeCount else { return nil }
            result["season"] = .number(Double(season)); result["episode"] = .number(Double(episode))
        }
        var metadata: [String: JSONValue] = [:]
        if let trailer = details.trailer, trailer.site == "IMDb", trailer.key.range(of: #"^tt\d+$"#, options: .regularExpression) != nil {
            metadata["imdbId"] = .string(trailer.key)
        }
        return (result, metadata)
    }
}
#endif
