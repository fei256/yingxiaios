#if os(iOS)
import SwiftUI
import Perception
import AVKit
import TVCore
import KSPlayer

private final class AudioServiceObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(name: Notification.Name, action: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in action() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// iPhone and iPad share one playback session, including while its PiP window owns the picture.
/// KSPlaybackEngine owns the active backend. Shared helpers retain a separate idle AVQueuePlayer.
@MainActor @Perceptible final class PlaybackSession {
    static let sharedLocal = PlaybackSession()
    static weak var current: PlaybackSession?
    let engine = KSPlaybackEngine()
    let player = AVQueuePlayer()
    let enhancer: VideoEnhancer
    let catalogDanmaku = CatalogDanmakuModel()
    @PerceptionIgnored lazy var mediaEnhancements = NativeMediaEnhancements(catalog: catalogDanmaku)
    let remoteSkip = NativeRemoteSkip()
    @PerceptionIgnored lazy var aiSubtitles = NativeAISubtitles(session: self)
    let externalSubtitles = ExternalSubtitles()
    let subtitles = SubtitleCues()
    var pictureInPictureActive = false
    @PerceptionIgnored var pictureInPictureController: PictureInPicture?
    var orientationPolicy = PlaybackOrientationPolicy()
    var history = PlaybackHistory.shared
    var skipDefaults = UserDefaults.standard
    var error: String?
    var loading = true
    var looping = false { didSet { if looping { discardUpcoming() } } }
    private(set) var buffering = false
    private(set) var showsPicture = false
    private(set) var errorSymbol = "play.slash.fill"
    private(set) var restoredPosition: Double?
    private(set) var requestedResumePosition: Double?
    private(set) var skipSettings = EpisodeSkipSettings()
    var position: Double { engine.position }
    var duration: Double { engine.duration }
    var paused: Bool { engine.paused }
    var muted: Bool { engine.muted }
    var hasTimeline: Bool { engine.isReady && engine.seekable && engine.duration > 0 && !isLive }
    private(set) var isLive = false
    private(set) var qualities: [StreamQuality] = []
    private(set) var quality: Int?
    var audioChoices: [UngroupedAudio.Choice] { [] }
    var audioChoice: CMPersistentTrackID? { engine.tracks.first { $0.kind == .audio && $0.selected }.flatMap { Int32($0.id) } }
    private(set) var activeChannelID: String?
    @PerceptionIgnored private var activeObserver: NSObjectProtocol?
    @PerceptionIgnored private var audioResetObserver: AudioServiceObservation?
    @PerceptionIgnored private var audioLostObserver: AudioServiceObservation?
    @PerceptionIgnored private var videoCacheObserver: NSObjectProtocol?
    @PerceptionIgnored private var cachePreparation: Task<Void, Never>?
    @PerceptionIgnored private var cachePreparationID = UUID()
    @PerceptionIgnored private var needsVideoCacheActivation = false
    @PerceptionIgnored private var recovery: Task<Void, Never>?
    @PerceptionIgnored private var recoveryAttempts = 0
    @PerceptionIgnored private var decoderRecoveryAttempts = 0
    @PerceptionIgnored private var lastRecovery: Date?
    var onPlaybackEnded: (() -> Void)?
    var onUnplayableFile: (() -> String?)?
    var upcomingEpisode: (@MainActor () async -> Channel?)?
    var playsOn: @MainActor () -> Bool = { false }
    var onAdvance: (@MainActor (Channel) -> Void)?
    static let upcomingLead = 30.0
    private(set) var boost: Float?
    private(set) var boostWanted: Float?
    var preferredSpeed: Float { selectedSpeed }
    @PerceptionIgnored private var selectedSpeed: Float = 1
    @PerceptionIgnored private var throttle: SpeedBoost.Throttle?
    @PerceptionIgnored private var generation = UUID()
    @PerceptionIgnored private var preparation: Task<Void, Never>?
    @PerceptionIgnored private var sampler: Task<Void, Never>?
    @PerceptionIgnored private var watchSampler = PlaybackWatchSampler()
    @PerceptionIgnored private var transferTicker: Task<Void, Never>?
    @PerceptionIgnored private var runtimePinTask: Task<Void, Never>?
    @PerceptionIgnored private var runtimePinnedURLs = Set<URL>()
    @PerceptionIgnored private var startupWork = PlaybackStartupWork()
    @PerceptionIgnored private var skipLookupEligible = false
    @PerceptionIgnored private var openingFrameTarget: Double?
    @PerceptionIgnored private var enhancementTicker: Task<Void, Never>?
    @PerceptionIgnored private var preparationStarted = Date()
    @PerceptionIgnored private var discSelection: Task<Void, Never>?
    @PerceptionIgnored private var discSelectionID = UUID()
    private(set) var selectingDiscTitle = false
    var currentPlaybackURL: URL? { _ = engine.mediaID; return currentPrepared?.url }
    var currentPlaybackHeaders: [String: String] { _ = engine.mediaID; return currentPrepared?.headers ?? [:] }
    var currentAudioSamplingUsesSeparateInput: Bool { _ = engine.mediaID; return currentPrepared?.audioURL != nil }
    var currentAudioSamplingURL: URL? {
        _ = engine.mediaID
        guard let prepared = currentPrepared else { return nil }
        return prepared.audioCacheIOURL ?? prepared.audioURL ?? prepared.cacheIOURL ?? prepared.url
    }
    var currentAudioSamplingHeaders: [String: String] {
        _ = engine.mediaID
        guard let prepared = currentPrepared else { return [:] }
        if prepared.audioURL != nil {
            return prepared.audioHeaders.isEmpty ? prepared.headers : prepared.audioHeaders
        }
        // The app-owned cache may redirect an extensionless HLS input to its
        // original manifest. Sampling must retain authorization on that path.
        return prepared.headers
    }
    var discTitles: [DiscPlaybackTitle] { _ = engine.mediaID; return currentPrepared?.disc?.titles ?? [] }
    var selectedDiscPlaylist: UInt32? { _ = engine.mediaID; return currentPrepared?.disc?.playlist }
    @PerceptionIgnored private var chat: BilibiliLiveChat?
    @PerceptionIgnored private var chatGeneration = UUID()
    @PerceptionIgnored private var playing: Channel?
    @PerceptionIgnored private var sourceChannel: Channel?
    @PerceptionIgnored private var historyContext: PlaybackHistoryContext?
    @PerceptionIgnored private var pendingResume: Double?
    @PerceptionIgnored private var restoringPosition = false
    @PerceptionIgnored private var skipScope: String?
    @PerceptionIgnored private var initialStartPending = false
    @PerceptionIgnored var scrubbing = false
    @PerceptionIgnored private var editingSkip = false
    @PerceptionIgnored private var resumeAfterEditing = false
    @PerceptionIgnored private var seekingSegment = false
    @PerceptionIgnored private var automatic: URL?
    @PerceptionIgnored private var currentPrepared: Prepared?
    private var sourceDanmaku: [Danmaku] = []
    @PerceptionIgnored private var automaticSourceLoad: Task<Void, Never>?
    @PerceptionIgnored private var sourceDanmakuLoading: Task<Void, Never>?
    @PerceptionIgnored private var sourceDanmakuGeneration = UUID()
    @PerceptionIgnored private var sourceDanmakuLoaded = false
    @PerceptionIgnored private var savedDownload = false
    private var switchNotice: String?
    @PerceptionIgnored private var healthyPrefetchSince: Date?
    @PerceptionIgnored private var upcomingTask: Task<Void, Never>?
    @PerceptionIgnored private var upcoming: (Channel, Prepared)?
    @PerceptionIgnored private var upcomingAttempted = false
    @PerceptionIgnored private var prefetchWarm: Task<Void, Never>?
    @PerceptionIgnored private var upcomingSkipWarm: Task<Void, Never>?
    @PerceptionIgnored private var prefetchComplete = false
    @PerceptionIgnored private var prefetchWarmID = UUID()
    @PerceptionIgnored private var advancing = false
    @PerceptionIgnored private var keepPausedAfterRestore = false
    private(set) var transfer = Transfer()
    private(set) var steps: [String] = []
    struct Transfer {
        var received: Int64 = 0
        var bytesPerSecond: Double?
        var required: Double?
        var host: String?
        var failure: String?
        var httpStatus: Int?
        var cachedBytes: Int64?
        var totalBytes: Int64?
        var cacheComplete = false
    }
    var cacheStatus: String? {
        guard let bytes = transfer.cachedBytes else { return nil }
        let cached = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if transfer.cacheComplete { return "缓存完成 · \(cached)" }
        if let total = transfer.totalBytes {
            return "已缓存 \(cached) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        return "已缓存 \(cached)"
    }
    var danmaku: [Danmaku] {
        guard catalogDanmaku.enabled else { return [] }
        if mediaEnhancements.hasSelectedTrack { return mediaEnhancements.comments }
        if catalogDanmaku.selection.hasExplicitChoice { return catalogDanmaku.renderedComments }
        return sourceDanmaku.isEmpty || !LocalDanmakuPreferences.builtinEnabled() ? catalogDanmaku.renderedComments : sourceDanmaku
    }
    var danmakuOpacity: Double { catalogDanmaku.opacity }
    var danmakuRevision: String {
        if mediaEnhancements.hasSelectedTrack { return mediaEnhancements.revision.uuidString }
        return sourceDanmaku.isEmpty || catalogDanmaku.selection.hasExplicitChoice ? catalogDanmaku.renderedRevision : ""
    }
    var danmakuSourceRevision: String {
        if mediaEnhancements.hasSelectedTrack { return mediaEnhancements.sourceRevision.uuidString }
        return sourceDanmaku.isEmpty || catalogDanmaku.selection.hasExplicitChoice
            ? catalogDanmaku.renderedRevision : (engine.mediaID ?? "") + "|source"
    }
    init() {
        enhancer = VideoEnhancer(player: player)
        externalSubtitles.cues = subtitles
        subtitles.externalStyledParts = { [weak engine] id, time in engine?.externalStyledParts(id, at: time) ?? [] }
        catalogDanmaku.nativeSourceReload = { [weak self] in await self?.loadSourceDanmaku() }
        externalSubtitles.waitForAutomaticLoad = { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.waitForStartupWork(.subtitles)
        }
        mediaEnhancements.waitForAutomaticLoad = { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.waitForStartupWork(.danmaku)
        }
        externalSubtitles.engine = engine
        externalSubtitles.changed = { [weak self] in self?.updateSubtitles() }
        subtitles.nativeChosen = { [weak self] in self?.externalSubtitles.nativeChosen() }
        engine.onUserSeek = { [weak self] time in
            self?.openingFrameTarget = nil
            self?.remoteSkip.userSought(to: time)
        }
        engine.onReady = { [weak self] in self?.ready() }
        engine.onTick = { [weak self] in self?.updatePictureState(); self?.updateSkipping(); self?.updateSubtitles() }
        engine.onFinish = { [weak self] error in self?.finished(error) }
        engine.onAudioServicesResume = { [weak self] context in
            self?.recoverPlayback(reusePrepared: true, audioServices: context) ?? false
        }
        engine.onReopenRequested = { [weak self] in self?.reopenCurrent() }
        engine.pictureInPictureSubtitleProvider = { [weak self] time in
            guard let self else { return (PlayerSubtitlePresentation(), PlayerSubtitlePresentation()) }
            self.subtitles.updateKS(lines: self.engine.subtitleLines, pictureSize: self.engine.presentationSize)
            self.subtitles.advance(to: time)
            let external = self.externalSubtitles.document != nil
            let primary = PlayerSubtitlePresentation(lines: self.subtitles.lines,
                styledParts: external ? self.subtitles.styledParts : self.engine.subtitleStyledParts,
                sourceTime: external ? self.subtitles.styledSourceTime : self.engine.subtitleSourceTime,
                bitmaps: self.engine.subtitleBitmaps)
            let usesAI = !self.aiSubtitles.lines.isEmpty
            let secondary = PlayerSubtitlePresentation(lines: usesAI ? self.aiSubtitles.lines : self.engine.secondarySubtitleLines,
                styledParts: usesAI ? [] : self.engine.secondarySubtitleStyledParts,
                sourceTime: self.engine.secondarySubtitleSourceTime,
                bitmaps: usesAI ? [] : self.engine.secondarySubtitleBitmaps)
            return (primary, secondary)
        }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverAfterForeground() }
        }
        audioResetObserver = AudioServiceObservation(name: AVAudioSession.mediaServicesWereResetNotification) { [weak self] in
            Task { @MainActor [weak self] in self?.audioServicesChanged(available: true) }
        }
        audioLostObserver = AudioServiceObservation(name: AVAudioSession.mediaServicesWereLostNotification) { [weak self] in
            Task { @MainActor [weak self] in self?.audioServicesChanged(available: false) }
        }
        videoCacheObserver = NotificationCenter.default.addObserver(forName: MobileMediaServices.videoCacheChanged,
            object: nil, queue: .main) { [weak self] notification in
            let enabled = notification.userInfo?["enabled"] as? Bool ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.needsVideoCacheActivation = enabled
                if enabled { self.activateVideoCache() }
                else {
                    self.cachePreparationID = UUID(); self.cachePreparation?.cancel(); self.cachePreparation = nil
                    self.transfer.cachedBytes = nil; self.transfer.totalBytes = nil; self.transfer.cacheComplete = false
                }
            }
        }
    }
    func togglePlayback() {
        sampleWatchActivity()
        if paused { engine.play() } else { engine.pause(); clearBoost() }
        sampleWatchActivity()
    }
    func skip(_ seconds: Double) {
        sampleWatchActivity(); watchSampler.interrupt()
        engine.seekFromUser(to: position + seconds)
    }
    func chooseAudio(_ id: CMPersistentTrackID) { engine.selectAudio(id: String(id)) }
    func setSpeed(_ speed: Float) { selectedSpeed = min(8, max(0.25, speed)); clearBoost(); engine.speed = selectedSpeed }
    func setBoost(_ rate: Float?) {
        guard rate == nil || !paused else { return }
        throttle = rate.map { SpeedBoost.Throttle(wanted: Double($0), after: throttle) }; applyBoost()
    }
    private func applyBoost() {
        boost = throttle.map { Float($0.rate) }; boostWanted = throttle.flatMap { $0.limited ? Float($0.wanted) : nil }
        engine.speed = boost ?? selectedSpeed
    }
    private func clearBoost() { throttle = nil; boost = nil; boostWanted = nil; engine.speed = selectedSpeed }
    func beginEditingSkip() {
        sampleWatchActivity()
        editingSkip = true; resumeAfterEditing = !paused; engine.pause()
        sampleWatchActivity()
    }
    func endEditingSkip() {
        editingSkip = false; if resumeAfterEditing { engine.play() }; resumeAfterEditing = false
        sampleWatchActivity()
    }
    func applySkipSettings(_ settings: EpisodeSkipSettings) {
        guard let skipScope else { return }
        settings.save(scope: skipScope, defaults: skipDefaults); skipSettings = settings; remoteSkip.settingsChanged()
    }
    func lineSwitchFailed(_ message: String) { switchNotice = nil; error = message; loading = false }
    func start(_ channel: Channel) {
        Self.current = self
        if sourceChannel == channel, error == nil, engine.mediaID != nil { return }
        stop()
        begin(channel); sourceChannel = channel
        let active = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == active { self.preparation = nil } }
            do {
                var next = channel
                var liveQualities: [StreamQuality] = [], liveQuality: Int?
                if let (platform, id) = LiveCatalog.room(channel.url), platform.chat == "bilibili", let room = Int(id) { self.listen(room: room) }
                if LiveCatalog.isRoom(channel.url) { (next, liveQualities, liveQuality) = try await LiveCatalog.resolve(channel) }
                let prepared = try await self.prepare(next)
                guard self.generation == active, !Task.isCancelled else { Self.release(next, prepared); return }
                self.playing = next
                self.currentPrepared = prepared
                self.automatic = prepared.url
                self.activeChannelID = channel.id
                let sourceQualities = PlaybackQualityRegistry.qualities(for: channel.url)
                self.qualities = sourceQualities.isEmpty ? liveQualities : sourceQualities
                self.quality = PlaybackQualityRegistry.selected(for: channel.url) ?? liveQuality
                self.open(prepared, channel: next)
                self.externalSubtitles.begin(next, playing: prepared.url)
                self.mediaEnhancements.begin(channel: channel, sessionID: active.uuidString.lowercased(), engine: self.engine)
                self.startSampler(generation: active)
            } catch {
                guard self.generation == active, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.loading = false
                Diagnostics.shared.failure("player", "KS prepare", error)
            }
        }
    }
    private func loadSourceDanmaku() async {
        guard LocalDanmakuPreferences.enabled(), LocalDanmakuPreferences.builtinEnabled(), !sourceDanmakuLoaded,
              let channel = sourceChannel, DanmakuSource.has(channel.url) else { return }
        if let sourceDanmakuLoading { await sourceDanmakuLoading.value; return }
        let active = sourceDanmakuGeneration
        let task = Task { [weak self] in
            guard let comments = await DanmakuSource.comments(for: channel.url), !Task.isCancelled, let self,
                  self.sourceDanmakuGeneration == active, !self.catalogDanmaku.selection.hasExplicitChoice,
                  LocalDanmakuPreferences.enabled(), LocalDanmakuPreferences.builtinEnabled() else { return }
            self.sourceDanmaku = comments; self.sourceDanmakuLoaded = true
            self.mediaEnhancements.sourceLoaded(count: comments.count)
        }
        sourceDanmakuLoading = task
        await task.value
        if sourceDanmakuGeneration == active { sourceDanmakuLoading = nil }
    }
    private func begin(_ channel: Channel) {
        engine.beginPlaybackRoute()
        watchSampler.reset()
        startupWork = PlaybackStartupWork()
        if DanmakuSource.has(channel.url), LocalDanmakuPreferences.enabled(), LocalDanmakuPreferences.builtinEnabled() {
            automaticSourceLoad = Task { [weak self] in
                guard let self else { return }
                do { try await self.waitForStartupWork(.danmaku) } catch { return }
                await self.loadSourceDanmaku()
            }
        }
        error = nil; loading = true; showsPicture = false; buffering = false; steps = ["正在解析播放地址"]
        preparationStarted = Date()
        transfer = Transfer(); transfer.host = channel.url.host()
        historyContext = channel.historyContext; requestedResumePosition = channel.resumePosition
        // Zero is an explicit restart. It must never become a lookup of the previous history.
        pendingResume = channel.resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        restoringPosition = false; restoredPosition = nil
        skipScope = channel.skipScope ?? channel.historyContext?.id ?? "direct:" + channel.id
        skipSettings = skipScope.map { EpisodeSkipSettings.load(scope: $0, defaults: skipDefaults) } ?? EpisodeSkipSettings()
        initialStartPending = true; seekingSegment = false
        savedDownload = channel.url.scheme == DownloadLibrary.scheme
        isLive = channel.playback?.isLive == true || MediaAddress.streamingSchemes.contains(channel.url.scheme?.lowercased() ?? "")
            || LiveCatalog.isRoom(channel.url) || channel.group == L10n.text("Bilibili Live") || MediaDanmakuRegistry.descriptor(for: channel.url)?.live != nil
        let source = channel.historyContext?.sourceKey
        if !DanmakuSource.has(channel.url), source != Bilibili.siteKey, source != CloudFiles.sourceKey { catalogDanmaku.startAutomatic(channel.historyContext) }
        ErrorReports.shared.playing(live: isLive, format: channel.playback?.format.isEmpty == false ? channel.playback!.format : channel.url.pathExtension,
                                    source: source, danmaku: catalogDanmaku.enabled, sharper: false)
    }
    private func open(_ prepared: Prepared, channel: Channel, selections: KSPlaybackSelections? = nil) {
        startupWork.observe(ready: false, now: ProcessInfo.processInfo.systemUptime)
        updateRuntimePlaybackPins(Set([channel.url, prepared.url, prepared.audioURL].compactMap { $0 }))
        error = nil; loading = true; showsPicture = false; buffering = false
        skipLookupEligible = false; openingFrameTarget = nil; seekingSegment = false
        remoteSkip.begin(channel: channel, isLive: isLive)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { Diagnostics.shared.failure("player", "KS audio session", error) }
        let descriptor = channel.playback
        steps = ["正在连接视频", "等待第一帧画面"]
        Diagnostics.shared.record(.info, "player.startup", "stage=prepared elapsed=\(Date().timeIntervalSince(preparationStarted)) live=\(isLive) format=\(descriptor?.format ?? "")")
        engine.open(url: prepared.url, headers: prepared.headers, mediaID: generation.uuidString,
                    format: prepared.disc == nil ? descriptor?.format : "mpegts", isLive: isLive,
                    audioURL: prepared.audioURL, audioHeaders: prepared.audioHeaders,
                    cacheIOURL: prepared.cacheIOURL, audioCacheIOURL: prepared.audioCacheIOURL, selections: selections)
        if selections != nil { externalSubtitles.restoreAfterReopen(channel) }
        engine.speed = selectedSpeed
        if keepPausedAfterRestore { engine.pause() }
        if let disc = prepared.disc {
            engine.setDiscChapters(disc.chapters.enumerated().map { index, chapter in
                KSPlaybackChapter(id: index, title: chapter.title, start: chapter.time,
                                  end: index + 1 < disc.chapters.count ? disc.chapters[index + 1].time : disc.duration)
            })
        }
        ExternalDisplay.shared.refresh()
    }
    private func updateRuntimePlaybackPins(_ addresses: Set<URL>) {
        let addresses = Set(addresses.filter {
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains($0.host?.lowercased() ?? "")
        })
        guard addresses != runtimePinnedURLs else { return }
        let removed = runtimePinnedURLs.subtracting(addresses)
        runtimePinnedURLs = addresses
        let previous = runtimePinTask
        runtimePinTask = Task {
            await previous?.value
            // Keep host commands ordered through rapid episode/core changes.
            // A delayed release of an old source cannot clear a newer owner.
            for url in removed {
                _ = await EmbeddedPythonHost.shared.setPlaybackPinned(url: url, pinned: false)
                _ = await EmbeddedNodeHost.shared.setPlaybackPinned(url, pinned: false)
            }
            // Multiple URLs may share one source proxy. Releasing its previous
            // address can release that source's owner, so reassert every desired
            // address after all removals rather than only newly added URLs.
            for url in addresses.sorted(by: { $0.absoluteString < $1.absoluteString }) {
                _ = await EmbeddedPythonHost.shared.setPlaybackPinned(url: url, pinned: true)
                _ = await EmbeddedNodeHost.shared.setPlaybackPinned(url, pinned: true)
            }
        }
    }
    private func ready() {
        guard recovery == nil else { return }
        buffering = false
        Diagnostics.shared.record(.info, "player.startup", "stage=ready elapsed=\(Date().timeIntervalSince(preparationStarted))")
        let resume = pendingResume.flatMap { PlaybackHistoryEntry.resumeTarget($0, duration: duration) }
        pendingResume = nil
        var opening: NativeRemoteSkip.Action?
        if initialStartPending && hasTimeline && !editingSkip && !scrubbing && !keepPausedAfterRestore && !paused {
            remoteSkip.refreshLocal(settings: skipSettings, duration: duration, chapters: engine.chapters,
                                    sessionID: mediaEnhancements.sessionID)
            opening = remoteSkip.nextAction(time: resume ?? position, duration: duration, playing: true,
                                            enabled: skipSettings.enabled, openingOnly: true)
        }
        initialStartPending = false
        if let target = opening?.target ?? resume {
            restoringPosition = true
            steps = [opening == nil ? "正在恢复播放进度" : "正在跳过片头"]
            seekAtStart(to: target, resume: resume, opening: opening)
        } else {
            loading = false
            if editingSkip { engine.pause() }
            keepPausedAfterRestore = false
        }
    }

    private func seekAtStart(to target: Double, resume: Double?, opening: NativeRemoteSkip.Action?) {
        let active = generation, input = engine.inputRevision
        engine.seek(to: target) { [weak self] success in
            guard let self, self.generation == active, self.engine.inputRevision == input else { return }
            if let opening {
                self.completedSkip(opening, succeeded: success)
                if !success, !self.engine.seeking, let resume {
                    self.seekAtStart(to: resume, resume: resume, opening: nil)
                    return
                }
            }
            self.restoringPosition = false; self.loading = false
            if success, resume != nil { self.restoredPosition = self.position }
            if !success, opening == nil, !self.engine.seeking {
                self.error = L10n.text("The player could not restore the saved position. Try again.")
            }
            if self.editingSkip { self.engine.pause() }
            self.keepPausedAfterRestore = false
        }
    }
    private func updateSubtitles() {
        subtitles.updateKS(lines: engine.subtitleLines, pictureSize: engine.presentationSize)
        subtitles.advance(to: engine.displayPosition)
        aiSubtitles.tick()
    }
    func prioritizeStartupWork(_ kind: PlaybackStartupWork.Kind) { startupWork.request(kind) }

    func endStartupPriority(_ kind: PlaybackStartupWork.Kind) { startupWork.endRequest(kind) }

    private func waitForStartupWork(_ kind: PlaybackStartupWork.Kind) async throws {
        let episode = sourceDanmakuGeneration
        while true {
            try Task.checkCancellation()
            guard sourceDanmakuGeneration == episode else { throw CancellationError() }
            if isLive || startupWork.isRequested(kind) { return }
            let competing = kind == .danmaku && (externalSubtitles.fetchingOffered || remoteSkip.matching)
            let now = ProcessInfo.processInfo.systemUptime
            // Give active metadata a short head start without starving comments on a slow service.
            if startupWork.allows(kind, now: competing ? now - 2 : now) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func updatePictureState() {
        let ready = recovery == nil && error == nil && engine.isReady && engine.hasPicture &&
            !engine.buffering && !engine.seeking && !restoringPosition && pendingResume == nil
        let speed = max(0.1, Double(engine.speed))
        let remaining = duration > 0 ? max(0, duration - position) : 2 * speed
        let headroom = engine.bufferedPosition - position
        let local = currentPrepared?.url.isFileURL == true
        let fps = engine.playbackInfo.frameRate ?? 24
        startupWork.observeProgress(ready: ready && !paused,
            mediaTime: engine.startupMediaTime, now: ProcessInfo.processInfo.systemUptime,
            stallTolerance: max(0.75, 2 / max(0.1, fps * speed)),
            hasHeadroom: local || headroom >= min(remaining, 1.5 * speed))
        let eligible = ready && !scrubbing && mediaEnhancements.serviceReady && startupWork.allows(.remoteSkip, now: ProcessInfo.processInfo.systemUptime)
        if eligible && !skipLookupEligible { updateSkipPlan(allowAutomatic: true) }
        skipLookupEligible = eligible
        if ready, let target = openingFrameTarget, let mediaTime = engine.startupMediaTime, mediaTime >= target - 0.05 {
            openingFrameTarget = nil
            Diagnostics.shared.record(.info, "player.startup", "stage=opening-picture elapsed=\(Date().timeIntervalSince(preparationStarted)) target=\(target) displayed=\(mediaTime)")
        }
        guard recovery == nil else { return }
        buffering = engine.buffering
        guard engine.isReady, !restoringPosition, pendingResume == nil else { return }
        loading = false
        if engine.hasPicture && !showsPicture {
            Diagnostics.shared.record(.info, "player.startup", "stage=first-picture elapsed=\(Date().timeIntervalSince(preparationStarted))")
            steps = []
        }
        showsPicture = engine.hasPicture
    }
    private func startSampler(generation active: UUID) {
        sampler?.cancel()
        transferTicker?.cancel()
        enhancementTicker?.cancel()
        transferTicker = Task { [weak self] in
            var rate = PlaybackTransferRate()
            var previousInput: UUID?, previousOrigin: Bool?
            var rateIdentity = UUID()
            while !Task.isCancelled {
                guard let self, self.generation == active else { return }
                let input = self.engine.inputRevision
                let owner = self.currentPrepared?.owner
                var bytes = self.engine.bytesRead, originStatistics = false
                var cacheStatistics: MobileMediaServices.VideoCacheStatistics?
                if let owner, let statistics = try? await MobileMediaServices.videoCacheStatistics(owner), !statistics.nativeFallback {
                    bytes = statistics.networkBytes
                    originStatistics = true
                    cacheStatistics = statistics
                }
                guard !Task.isCancelled, self.generation == active, self.engine.inputRevision == input,
                      self.currentPrepared?.owner == owner else { return }
                if previousInput != input || previousOrigin != originStatistics {
                    rateIdentity = UUID(); previousInput = input; previousOrigin = originStatistics
                }
                self.transfer.cachedBytes = cacheStatistics.flatMap { $0.cacheEnabled ? $0.cachedMediaBytes : nil }
                self.transfer.totalBytes = cacheStatistics?.mediaBytes
                self.transfer.cacheComplete = cacheStatistics.map { $0.cacheEnabled && $0.complete } ?? false
                self.transfer.bytesPerSecond = rate.sample(bytes: bytes, at: ProcessInfo.processInfo.systemUptime,
                    identity: rateIdentity)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Network-backed comments must never hold the picture/readiness sampler.
        enhancementTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == active else { return }
                await self.mediaEnhancements.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        sampler = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self, self.generation == active else { return }
                self.buffering = self.engine.buffering
                self.updatePictureState()
                if self.needsVideoCacheActivation { self.activateVideoCache() }
                let bytes = self.engine.bytesRead
                self.transfer.received = bytes
                self.transfer.required = self.engine.bitrate > 0 ? self.engine.bitrate / 8 : nil
                if var throttle = self.throttle, !self.paused {
                    throttle.update(ahead: max(0, self.engine.bufferedPosition - self.position), waiting: self.buffering)
                    self.throttle = throttle; self.applyBoost()
                }
                self.updateSkipPlan(allowAutomatic: self.skipLookupEligible)
                self.updateSkipping()
                self.queueUpcomingIfDue()
                self.sampleWatchActivity()
                ticks += 1
                if ticks % 5 == 0 { self.saveHistory() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func updateSkipPlan(allowAutomatic: Bool) {
        remoteSkip.tick(settings: skipSettings, duration: duration, chapters: engine.chapters,
                        sessionID: mediaEnhancements.sessionID, ready: mediaEnhancements.serviceReady, allowAutomatic: allowAutomatic)
    }

    private func completedSkip(_ action: NativeRemoteSkip.Action, succeeded: Bool) {
        remoteSkip.complete(action, succeeded: succeeded)
        if succeeded && action.kind == "opening" { openingFrameTarget = action.target }
    }

    private func updateSkipping() {
        guard !remoteSkip.segments.isEmpty, hasTimeline, !initialStartPending, !editingSkip, !scrubbing,
              !seekingSegment, !engine.seeking, pendingResume == nil, !restoringPosition, recovery == nil, error == nil else { return }
        guard let action = remoteSkip.nextAction(time: position, duration: duration, playing: !engine.paused && !engine.buffering, enabled: skipSettings.enabled) else { return }
        sampleWatchActivity(); watchSampler.interrupt()
        seekingSegment = true
        let active = generation, input = engine.inputRevision
        engine.seek(to: action.target) { [weak self] success in
            guard let self, self.generation == active, self.engine.inputRevision == input else { return }
            self.seekingSegment = false
            self.completedSkip(action, succeeded: success)
        }
    }
    private func finished(_ failure: Error?) {
        if let failure, PlaybackAudioFailure.isUnavailable(failure) {
            engine.pause(); error = failure.localizedDescription; loading = false; buffering = false
            return
        }
        guard recovery == nil else { return }
        if let failure {
            Diagnostics.shared.record(.warning, "player.recovery", "event=failure code=\(PlaybackFailureDiagnostics.codes(failure)) attempts=\(recoveryAttempts) decoderAttempts=\(decoderRecoveryAttempts) \(engine.failureDiagnostic)")
            if failure is KSPlaybackFailure {
                // First-open incompatibility needs another line/decoder. Only a
                // decoder that already presented this input may be rebuilt once.
                if engine.hasPresentedPicture, decoderRecoveryAttempts == 0,
                   recoverPlayback(reusePrepared: true) { decoderRecoveryAttempts += 1; return }
            } else if recoverPlayback() { return }
            engine.pause()
            error = failure.localizedDescription; loading = false; buffering = false
            Diagnostics.shared.record(.error, "player.recovery", "event=terminal code=\(PlaybackFailureDiagnostics.codes(failure)) \(engine.failureDiagnostic)")
            return
        }
        if looping {
            sampleWatchActivity(); watchSampler.interrupt()
            engine.seek(to: 0) { [weak self] ok in if ok { self?.engine.play() } }
            return
        }
        saveHistory(completed: true)
        if playsOn(), playUpcoming() { return }
        onPlaybackEnded?()
    }
    func saveHistory(completed: Bool = false, item: AVPlayerItem? = nil) {
        sampleWatchActivity()
        guard let context = historyContext else { return }
        let activity = watchSampler.drain(identity: history.recordingIdentity(for: context))
        guard engine.isReady, pendingResume == nil, !restoringPosition, !seekingSegment, !engine.seeking else {
            history.recordWatchActivity(for: context, activity: activity)
            return
        }
        history.record(context, position: completed && duration > 0 ? duration : position, duration: duration,
                       watchActivity: activity.isEmpty ? nil : activity)
    }
    private func sampleWatchActivity() {
        watchSampler.sample(identity: historyContext.map { history.recordingIdentity(for: $0) },
                            playing: historyContext != nil && historyContext?.readingProgress == nil && !isLive && engine.isReady
                                && !paused && !buffering && !loading && pendingResume == nil && !restoringPosition
                                && !seekingSegment && !editingSkip && !engine.seeking,
                            position: position, speed: Double(engine.speed))
    }
    func choose(quality: Int?) {
        guard let channel = playing, quality != self.quality else { return }
        let sourceURL = sourceChannel?.url ?? channel.url, requested = quality
        let savedPosition = position, wasPaused = paused
        cancelDiscSelection()
        recovery?.cancel(); recovery = nil
        preparation?.cancel(); discardUpcoming(); saveHistory()
        generation = UUID(); let active = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == active { self.preparation = nil } }
            do {
                var next: Channel
                if let resolved = try await PlaybackQualityRegistry.resolve(for: sourceURL, quality: requested) {
                    next = Channel(name: channel.name, group: resolved.group, url: resolved.url, logo: channel.logo,
                                   headers: resolved.headers, skipScope: channel.skipScope, historyContext: channel.historyContext,
                                   resumePosition: savedPosition, subtitles: resolved.subtitles, playback: resolved.playback)
                } else if let url = requested.flatMap({ id in self.qualities.first { $0.id == id }?.url }) ?? self.automatic {
                    next = Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo, headers: channel.headers,
                                   skipScope: channel.skipScope, historyContext: channel.historyContext, resumePosition: savedPosition,
                                   subtitles: channel.subtitles, playback: channel.playback)
                } else { return }
                if LiveCatalog.isRoom(next.url) { next = try await LiveCatalog.resolve(next).channel }
                let prepared = try await self.prepare(next)
                guard self.generation == active, !Task.isCancelled else { Self.release(next, prepared); return }
                if let previous = self.currentPrepared { Self.release(channel, previous) }
                self.pendingResume = savedPosition; self.restoringPosition = false; self.keepPausedAfterRestore = wasPaused
                self.currentPrepared = prepared; self.quality = requested; self.playing = next
                self.externalSubtitles.begin(next, playing: prepared.url)
                self.open(prepared, channel: next)
                self.startSampler(generation: active)
            } catch {
                guard self.generation == active, !Task.isCancelled else { return }
                self.switchNotice = error.localizedDescription
                self.startSampler(generation: active)
            }
        }
    }
    private func reopenCurrent() {
        guard !engine.requiresAudioServicesResume else { return }
        guard let channel = playing, let prepared = currentPrepared else { return }
        cancelDiscSelection()
        recovery?.cancel(); recovery = nil
        preparation?.cancel(); preparation = nil
        saveHistory(); pendingResume = pendingResume ?? position; keepPausedAfterRestore = keepPausedAfterRestore || paused
        let selections = engine.selections
        externalSubtitles.prepareForReopen()
        generation = UUID()
        open(prepared, channel: channel, selections: selections); startSampler(generation: generation)
    }
    private func activateVideoCache() {
        if currentPrepared?.owner != nil { needsVideoCacheActivation = false; return }
        guard cachePreparation == nil, preparation == nil, recovery == nil, !isLive,
              !engine.pictureInPictureActive, !PictureInPicture.shared.busy, !engine.seeking, !restoringPosition,
              !selectingDiscTitle, let channel = playing, let original = currentPrepared,
              original.owner == nil, original.disc == nil, engine.mediaID != nil else { return }
        let active = generation, input = engine.inputRevision, identity = UUID()
        cachePreparationID = identity
        cachePreparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.cachePreparationID == identity { self.cachePreparation = nil } }
            do {
                let prepared = try await self.prepare(channel)
                guard !Task.isCancelled, self.cachePreparationID == identity, self.generation == active,
                      self.playing?.id == channel.id, self.preparation == nil, self.recovery == nil,
                      self.engine.inputRevision == input, !self.engine.pictureInPictureActive, !PictureInPicture.shared.busy,
                      !self.engine.seeking, !self.restoringPosition else { Self.release(channel, prepared); return }
                guard prepared.owner != nil else {
                    self.needsVideoCacheActivation = false
                    Self.release(channel, prepared)
                    return
                }
                let selections = self.engine.selections
                // Reading and cache setup leave the active player running. Use
                // the latest transport state when the replacement is ready.
                self.pendingResume = self.pendingResume ?? self.position
                self.keepPausedAfterRestore = self.paused
                self.restoringPosition = false
                self.currentPrepared = prepared
                self.needsVideoCacheActivation = false
                self.externalSubtitles.prepareForReopen()
                self.generation = UUID()
                self.open(prepared, channel: channel, selections: selections)
                if self.keepPausedAfterRestore { self.engine.pause() }
                self.startSampler(generation: self.generation)
                Self.release(channel, original)
            } catch {
                guard !Task.isCancelled, self.cachePreparationID == identity, self.generation == active else { return }
                self.needsVideoCacheActivation = false
                self.switchNotice = error.localizedDescription
            }
        }
    }
    func selectDiscTitle(_ playlist: UInt32) {
        guard !selectingDiscTitle, let channel = playing, let previous = currentPrepared,
              let disc = previous.disc, disc.playlist != playlist,
              disc.titles.contains(where: { $0.playlist == playlist }), let backing = previous.backingURL else { return }
        cancelDiscSelection()
        recovery?.cancel(); recovery = nil
        generation = UUID()
        preparation?.cancel(); preparation = nil; discardUpcoming()
        startSampler(generation: generation)
        selectingDiscTitle = true
        let active = generation, selection = discSelectionID, wasPaused = paused
        discSelection = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.discSelectionID == selection { self.selectingDiscTitle = false; self.discSelection = nil }
            }
            do {
                let replacement = try await DiscPlayback.prepare(url: backing, headers: previous.backingHeaders, playlist: playlist)
                guard self.generation == active, self.discSelectionID == selection, !Task.isCancelled else { replacement.close(); return }
                self.engine.shutdown()
                previous.disc?.close()
                let prepared = Prepared(url: replacement.playbackURL, headers: [:], backingURL: backing,
                                        backingHeaders: previous.backingHeaders, disc: replacement)
                self.pendingResume = nil; self.restoringPosition = false; self.keepPausedAfterRestore = wasPaused
                self.currentPrepared = prepared; self.loading = true; self.showsPicture = false; self.error = nil
                var descriptor = channel.playback ?? PlaybackDescriptor(format: "iso")
                descriptor.discPlaylist = Int(playlist)
                self.playing = channel.withPlayback(descriptor)
                if let source = self.sourceChannel { self.sourceChannel = source.withPlayback(descriptor) }
                self.open(prepared, channel: channel)
                if wasPaused { self.engine.pause() }
            } catch {
                guard self.generation == active, self.discSelectionID == selection, !Task.isCancelled else { return }
                self.switchNotice = error.localizedDescription
            }
        }
    }
    private func cancelDiscSelection() {
        discSelectionID = UUID(); discSelection?.cancel(); discSelection = nil; selectingDiscTitle = false
    }
    func stop() {
        updateRuntimePlaybackPins([])
        needsVideoCacheActivation = false
        cachePreparationID = UUID(); cachePreparation?.cancel(); cachePreparation = nil
        cancelDiscSelection()
        saveHistory()
        generation = UUID()
        recovery?.cancel(); recovery = nil; recoveryAttempts = 0; decoderRecoveryAttempts = 0; lastRecovery = nil
        enhancementTicker?.cancel(); enhancementTicker = nil; selectingDiscTitle = false
        preparation?.cancel(); preparation = nil; sampler?.cancel(); sampler = nil
        transferTicker?.cancel(); transferTicker = nil
        discardUpcoming()
        if let playing, let currentPrepared { Self.release(playing, currentPrepared) }
        currentPrepared = nil; automatic = nil
        aiSubtitles.stop()
        remoteSkip.stop(); mediaEnhancements.stop(); externalSubtitles.stop(); subtitles.resetKS()
        engine.shutdown(); player.pause(); player.removeAllItems()
        watchSampler.reset()
        catalogDanmaku.clear(); sourceDanmaku = []; chatGeneration = UUID(); chat?.stop(); chat = nil
        sourceDanmakuGeneration = UUID()
        automaticSourceLoad?.cancel(); automaticSourceLoad = nil
        sourceDanmakuLoading?.cancel(); sourceDanmakuLoading = nil; sourceDanmakuLoaded = false
        if playing != nil { ErrorReports.shared.stoppedPlaying() }
        playing = nil; sourceChannel = nil; activeChannelID = nil; historyContext = nil; pendingResume = nil
        requestedResumePosition = nil; restoredPosition = nil; restoringPosition = false; keepPausedAfterRestore = false
        skipScope = nil; initialStartPending = false; scrubbing = false; skipSettings = EpisodeSkipSettings()
        editingSkip = false; resumeAfterEditing = false; seekingSegment = false
        transfer = Transfer(); steps = []; switchNotice = nil; orientationPolicy = PlaybackOrientationPolicy()
        qualities = []; quality = nil; showsPicture = false; buffering = false; loading = true
        onPlaybackEnded = nil; onUnplayableFile = nil; upcomingEpisode = nil; onAdvance = nil; playsOn = { false }
        clearBoost(); healthyPrefetchSince = nil; upcomingAttempted = false; advancing = false
    }
    private func recoverAfterForeground() {
        guard let prepared = currentPrepared, engine.mediaID != nil else { return }
        // The cache, HLS proxy and disc reader intentionally use loopback URLs.
        // Returning from PiP changes the surface; it does not invalidate any of those readers.
        engine.resumeAfterForeground()
        guard !paused else { return }
        if prepared.disc?.isAvailable == false || error != nil { _ = recoverPlayback() }
    }
    private func audioServicesChanged(available: Bool) {
        let hadPlayback = engine.mediaID != nil || currentPrepared != nil
        if hadPlayback {
            saveHistory(); watchSampler.interrupt()
            recovery?.cancel(); recovery = nil
            cancelDiscSelection(); discardUpcoming()
            cachePreparationID = UUID(); cachePreparation?.cancel(); cachePreparation = nil
        }
        engine.suspendForAudioServices(available: available)
        if hadPlayback {
            clearBoost()
            loading = false; buffering = false; showsPicture = false
            error = available ? "音频服务已重置，请点重试继续播放。" : "系统音频服务暂不可用，请稍后重试。"
            Diagnostics.shared.record(.warning, "player.audio", "event=media-services \(available ? "reset" : "lost")")
        }
    }
    @discardableResult private func recoverPlayback(reusePrepared: Bool = false, audioServices: KSAudioServicesResumeContext? = nil) -> Bool {
        guard audioServices != nil || !engine.requiresAudioServicesResume else { return false }
        guard recovery == nil, audioServices != nil || recoveryAttempts < 2, !selectingDiscTitle,
              preparation == nil || engine.mediaID == generation.uuidString,
              let selected = playing ?? sourceChannel else { return false }
        let source: Channel
        if !reusePrepared, let room = sourceChannel, LiveCatalog.isRoom(room.url) { source = room }
        else { source = selected }
        if reusePrepared, currentPrepared == nil { return false }
        if audioServices == nil, let lastRecovery, Date().timeIntervalSince(lastRecovery) < 2 { return false }
        if audioServices != nil { recoveryAttempts = 0; lastRecovery = nil }
        saveHistory()
        cancelDiscSelection()
        preparation?.cancel(); preparation = nil; discardUpcoming()
        recoveryAttempts += 1; lastRecovery = Date()
        Diagnostics.shared.record(.info, "player.recovery", "event=begin reuseInput=\(reusePrepared) attempt=\(recoveryAttempts) \(engine.failureDiagnostic)")
        let savedPosition = pendingResume ?? audioServices?.position ?? position, savedTimeline = engine.timelineRevision
        generation = UUID(); let active = generation
        restoringPosition = false; seekingSegment = false; pendingResume = nil
        preparationStarted = Date()
        error = nil; loading = true; buffering = false
        steps = [audioServices != nil ? "正在恢复音频服务" : reusePrepared ? "正在恢复视频解码" : "正在重新解析播放地址"]
        recovery = Task { [weak self] in
            guard let self, self.generation == active, !Task.isCancelled else { return }
            do {
                let channel = !reusePrepared && LiveCatalog.isRoom(source.url) ? try await LiveCatalog.resolve(source).0 : source
                let prepared: Prepared
                if reusePrepared, let current = self.currentPrepared { prepared = current }
                else { prepared = try await self.prepare(channel) }
                guard self.generation == active, !Task.isCancelled else {
                    if !reusePrepared { Self.release(channel, prepared) }
                    return
                }
                // Take the latest intent: pause/seek can be used while network
                // preparation runs. Shutdown callbacks belong to the old epoch.
                let wasPaused = self.paused
                let resume = audioServices == nil && (self.engine.seeking || self.engine.timelineRevision != savedTimeline) ? self.position : savedPosition
                let selections = audioServices?.selections ?? self.engine.selections
                self.externalSubtitles.prepareForReopen()
                self.engine.shutdown()
                if !reusePrepared, let previous = self.currentPrepared { Self.release(source, previous) }
                self.currentPrepared = prepared; self.playing = channel
                self.pendingResume = self.isLive ? nil : resume; self.keepPausedAfterRestore = wasPaused
                self.recovery = nil
                self.open(prepared, channel: channel, selections: selections)
                self.startSampler(generation: active)
                Diagnostics.shared.record(.info, "player.recovery", "event=reopened attempt=\(self.recoveryAttempts) resume=\(self.pendingResume ?? 0) paused=\(wasPaused)")
            } catch {
                guard self.generation == active, !Task.isCancelled else { return }
                self.engine.pause()
                self.error = error.localizedDescription; self.loading = false; self.buffering = false
                Diagnostics.shared.record(.error, "player.recovery", "event=prepare-failed code=\(PlaybackFailureDiagnostics.codes(error)) attempt=\(self.recoveryAttempts)")
            }
            if self.generation == active { self.recovery = nil }
        }
        return true
    }
    private func listen(room: Int) {
        chat?.stop()
        chatGeneration = UUID()
        let activeChat = chatGeneration
        let chat = BilibiliLiveChat(room: room); self.chat = chat
        chat.start { [weak self] text, color, position in
            Task { @MainActor [weak self] in
                guard let self, self.chatGeneration == activeChat else { return }
                self.sourceDanmaku.append(Danmaku(time: max(self.position + 0.2, self.sourceDanmaku.last?.time ?? 0), position: position, color: color, text: text))
                if self.sourceDanmaku.count > 4000 { self.sourceDanmaku.removeFirst(1000) }
            }
        }
    }
    private struct Prepared {
        var url: URL
        var headers: [String: String]
        var owner: String?
        var backingURL: URL?
        var backingHeaders: [String: String] = [:]
        var disc: DiscPlaybackResource?
        var audioURL: URL?
        var audioHeaders: [String: String] = [:]
        var cacheIOURL: URL?
        var audioCacheIOURL: URL?
    }
    private func prepare(_ channel: Channel) async throws -> Prepared {
        var address = channel.url
        var headers = channel.headers
        try Task.checkCancellation()
        // A source's HTTP URL is already a native FFmpeg input. Only relocate
        // a suspended local server; keep its path, selected quality and query.
        if address.scheme == "http", ["127.0.0.1", "localhost"].contains(address.host ?? ""),
           let relocated = await EmbeddedNodeHost.shared.relocate(address) { address = relocated }
        if CloudFiles.isFile(address) { address = try await CloudFiles.prepare(address) }
        if let source = await CloudStreams.source(for: address) {
            address = source.url; headers.merge(source.headers) { _, value in value }
        }
        try Task.checkCancellation()
        if address.scheme == DownloadLibrary.scheme {
            address = try await DownloadLibrary.shared.playbackAddress(for: address, preserveContainer: true) { _ in }
        }
        if address.scheme == HongguoStreams.scheme {
            address = try await HongguoStreams.playbackURL(for: address)
        }
        if let upstream = LiveRepair.upstream(address) {
            headers.merge(LiveRepair.headers(for: address)) { _, value in value }; address = upstream
        }
        if DiscPlayback.canHandle(url: address, format: channel.playback?.format) {
            let playlist = channel.playback?.discPlaylist.flatMap { $0 >= 0 && $0 <= Int(UInt32.max) ? UInt32($0) : nil }
            let disc = try await DiscPlayback.prepare(url: address, headers: headers, playlist: playlist)
            do { try Task.checkCancellation() }
            catch { disc.close(); throw error }
            return Prepared(url: disc.playbackURL, headers: [:], backingURL: address, backingHeaders: headers, disc: disc)
        }
        var descriptor = channel.playback
        if let audio = descriptor?.audioURL, audio.scheme == "http", ["127.0.0.1", "localhost"].contains(audio.host ?? ""),
           let relocated = await EmbeddedNodeHost.shared.relocate(audio) { descriptor?.audioURL = relocated }
        let next = Channel(name: channel.name, group: channel.group, url: address, logo: channel.logo, headers: headers,
                           skipScope: channel.skipScope, historyContext: channel.historyContext, resumePosition: channel.resumePosition,
                           subtitles: channel.subtitles, playback: descriptor)
        let prepared = try await MobileMediaServices.preparePlayable(next,
            cacheEnabled: UserDefaults.standard.object(forKey: "local.videoCache.enabled") as? Bool ?? true,
            sizeGB: max(1, min(4, UserDefaults.standard.integer(forKey: "local.videoCache.sizeGB"))),
            adClean: UserDefaults.standard.object(forKey: "local.hlsAdClean") as? Bool ?? true, isLive: isLive)
        return Prepared(url: prepared.url, headers: prepared.headers, owner: prepared.ownerID, backingURL: address,
                        audioURL: prepared.audioURL, audioHeaders: prepared.audioHeaders,
                        cacheIOURL: prepared.cacheIOURL, audioCacheIOURL: prepared.audioCacheIOURL)
    }
    private static func release(_ channel: Channel, _ prepared: Prepared) {
        if let owner = prepared.owner { Task { _ = try? await MobileMediaServices.call("playback.release", ["id": .string(owner)]) } }
        prepared.disc?.close()
        HongguoStreams.stop(channel.url)
        CloudStreams.stop(prepared.backingURL ?? prepared.url)
    }
    private var canPrefetchUpcoming: Bool {
        let enabled = UserDefaults.standard.object(forKey: "local.playback.prefetchNext") as? Bool ?? true
        return NextMediaPolicy.mayPrepare(enabled: enabled, paused: paused, buffering: buffering,
            seeking: engine.seeking || restoringPosition || seekingSegment || scrubbing, bufferedSeconds: engine.bufferedPosition - position,
            speed: Double(engine.speed), remainingSeconds: duration - position)
    }

    private func queueUpcomingIfDue() {
        guard canPrefetchUpcoming else {
            healthyPrefetchSince = nil
            if upcomingTask != nil {
                upcomingTask?.cancel(); upcomingTask = nil; upcomingAttempted = false
            }
            upcomingSkipWarm?.cancel(); upcomingSkipWarm = nil
            prefetchWarmID = UUID(); prefetchWarm?.cancel(); prefetchWarm = nil
            return
        }
        if healthyPrefetchSince == nil { healthyPrefetchSince = Date() }
        if upcoming != nil { warmUpcomingIfSafe(); return }
        let remaining = skipSettings.enabled && playsOn()
            ? RemoteEpisodeSkipPlan.remainingPlayback(time: position, duration: duration, segments: remoteSkip.segments)
            : duration - position
        guard Date().timeIntervalSince(healthyPrefetchSince!) >= 3, !upcomingAttempted, !looping, !isLive,
              duration > 0, remaining < Self.upcomingLead * Double(max(1, engine.speed)), let upcomingEpisode else { return }
        upcomingAttempted = true; let active = generation
        upcomingTask = Task { [weak self] in
            defer { if !Task.isCancelled, self?.generation == active { self?.upcomingTask = nil } }
            guard let next = await upcomingEpisode(), let self, self.generation == active, !Task.isCancelled else { return }
            if self.canPrefetchUpcoming { self.warmUpcomingOpening(next) }
            do {
                let prepared = try await self.prepare(next)
                guard self.generation == active, !Task.isCancelled else { Self.release(next, prepared); return }
                self.upcoming = (next, prepared); self.prefetchComplete = false; self.warmUpcomingIfSafe()
            } catch {
                if !Task.isCancelled { Diagnostics.shared.record(.warning, "player", "KS next preparation: \(error.localizedDescription)") }
            }
        }
    }
    private func warmUpcomingIfSafe() {
        guard canPrefetchUpcoming, let since = healthyPrefetchSince, Date().timeIntervalSince(since) >= 3 else { return }
        if let next = upcoming?.0 { warmUpcomingOpening(next) }
        guard !prefetchComplete, prefetchWarm == nil, let owner = upcoming?.1.owner else { return }
        let active = generation, warmID = UUID()
        prefetchWarmID = warmID
        prefetchWarm = Task { [weak self] in
            do {
                let complete = try await MobileMediaServices.prefetchPlayback(owner)
                guard let self, self.generation == active, self.prefetchWarmID == warmID, !Task.isCancelled else { return }
                self.prefetchComplete = complete
            } catch {}
            if let self, self.generation == active, self.prefetchWarmID == warmID { self.prefetchWarm = nil }
        }
    }
    private func warmUpcomingOpening(_ next: Channel) {
        guard upcomingSkipWarm == nil, playsOn(), next.playback?.isLive != true,
              let scope = next.skipScope ?? next.historyContext?.id else { return }
        let settings = EpisodeSkipSettings.load(scope: scope, defaults: skipDefaults)
        if settings.enabled && settings.introEnd <= 0 {
            upcomingSkipWarm = Task { [remoteSkip] in await remoteSkip.prefetch(next) }
        }
    }
    private func discardUpcoming() {
        upcomingSkipWarm?.cancel(); upcomingSkipWarm = nil
        prefetchWarmID = UUID(); prefetchWarm?.cancel(); prefetchWarm = nil; prefetchComplete = false
        upcomingTask?.cancel(); upcomingTask = nil
        if let (channel, prepared) = upcoming { Self.release(channel, prepared) }; upcoming = nil
    }
    func playUpcoming() -> Bool {
        guard let (channel, prepared) = upcoming, !advancing else { return false }
        advancing = true; upcoming = nil
        let advance = onAdvance, end = onPlaybackEnded, resolve = upcomingEpisode, shouldPlay = playsOn
        saveHistory()
        stop(); begin(channel); sourceChannel = channel
        onAdvance = advance; onPlaybackEnded = end; upcomingEpisode = resolve; playsOn = shouldPlay
        playing = channel; currentPrepared = prepared; automatic = prepared.url; activeChannelID = channel.id
        qualities = PlaybackQualityRegistry.qualities(for: channel.url)
        quality = PlaybackQualityRegistry.selected(for: channel.url)
        open(prepared, channel: channel)
        externalSubtitles.begin(channel, playing: prepared.url)
        mediaEnhancements.begin(channel: channel, sessionID: generation.uuidString.lowercased(), engine: engine)
        startSampler(generation: generation)
        onAdvance?(channel)
        advancing = false
        return true
    }
    var loadingProgress: LoadingProgress {
        var progress = LoadingProgress(title: L10n.text(loading ? "Connecting…" : "Buffering…"))
        progress.steps = steps
        if let switchNotice { progress.reason = switchNotice }
        else if let failure = transfer.failure { progress.reason = failure }
        if let speed = transfer.bytesPerSecond { progress.detail = L10n.text("Downloading at %@", Self.rate(speed)) }
        return progress
    }
    func wait(elapsed: TimeInterval, resume: Double?, linesHint: Bool) -> PlaybackWait {
        var result = PlaybackWait(message: loading ? Self.preparing(resume) : L10n.text("Buffering…"), caption: switchNotice,
                                  suggestsLines: linesHint && elapsed >= LoadingCard.patience)
        if elapsed >= PlaybackWait.detailsAfter { result.detail = loadingProgress.detail; result.steps = steps }
        return result
    }
    static func server(_ host: String?) -> String {
        guard let host, !host.isEmpty, !["127.0.0.1", "localhost"].contains(host) else { return L10n.text("the video server") }; return host
    }
    private static func rate(_ value: Double) -> String {
        L10n.text("%@/s", ByteCountFormatter.string(fromByteCount: Int64(value.isFinite ? min(1e15, max(0, value)) : 0), countStyle: .file))
    }
    static func preparing(_ resume: Double?) -> String {
        guard let resume, resume.isFinite, resume >= 5 else { return L10n.text("Getting it ready") }
        return L10n.text("Getting it ready · from %@", Duration.seconds(Int(resume)).formatted(.time(pattern: resume >= 3600 ? .hourMinuteSecond : .minuteSecond)))
    }
}
#endif
