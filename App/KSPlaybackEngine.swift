#if os(iOS)
import Foundation
import Perception
import UIKit
import AVKit
import AudioToolbox
import TVCore
import KSPlayer

/// AVFoundation can wait inside accessLog(). Only copy its counters on the worker.
private final class NativePlaybackLog: @unchecked Sendable {
    let item: AVPlayerItem
    init(_ item: AVPlayerItem) { self.item = item }
    func counters() -> (drops: Int?, bytes: Int64) {
        let events = item.accessLog()?.events ?? []
        let drops = events.map(\.numberOfDroppedVideoFrames).filter { $0 >= 0 }
        return (drops.isEmpty ? nil : drops.reduce(0, +), events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) })
    }
}

struct KSPlaybackFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct KSAudioServicesResumeContext: Sendable {
    let mediaID: String
    let position: Double
    let duration: Double
    let selections: KSPlaybackSelections
}

struct KSPlaybackTrack: Identifiable, Equatable {
    enum Kind: String { case video, audio, subtitle }
    let id: String
    let kind: Kind
    let title: String
    var codec: String?
    var language: String?
    var selected: Bool
    var width: Int? = nil
    var height: Int? = nil
}
struct KSPlaybackSubtitleBitmap: Identifiable, Equatable {
    let id: Int
    let image: UIImage
    let origin: CGPoint
    let canvasSize: CGSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.image === rhs.image && lhs.origin == rhs.origin && lhs.canvasSize == rhs.canvasSize
    }
}


/// Cached parts keep stable identities between clock ticks, including overlapping ASS cues.
@MainActor private final class KSExternalSubtitleDocument {
    let document: SubtitleDocument
    var timing: SubtitleTiming
    private var index: KSExternalSubtitleIndex?
    private var preparation: Task<Void, Never>?
    init(_ document: SubtitleDocument, timing: SubtitleTiming) {
        self.document = document; self.timing = timing
    }
    deinit { preparation?.cancel() }
    func parts(at time: Double, styledOnly: Bool = false) -> [SubtitlePart] {
        if styledOnly && !document.format.isStyled { return [] }
        if let index { return styledOnly && !index.styled ? [] : index.parts(at: time) }
        if preparation == nil {
            preparation = Task.detached(priority: .utility) { [weak self, document] in
                guard let index = KSExternalSubtitleIndex(document), !Task.isCancelled else { return }
                await self?.install(index)
            }
        }
        return []
    }
    private func install(_ value: KSExternalSubtitleIndex) { index = value; preparation = nil }
}

// The worker constructs the cue objects privately, then transfers them to the main actor.
private final class KSExternalSubtitleIndex: @unchecked Sendable {
    private let cues: [SubtitlePart]
    private let reach: [Double]
    let styled: Bool
    init?(_ document: SubtitleDocument) {
        var parts: [SubtitlePart] = []
        if document.format.isStyled, let text = document.sourceText {
            let parser = AssParse(), scanner = Scanner(string: text)
            _ = scanner.scanCharacters(from: .controlCharacters)
            if parser.canParse(scanner: scanner) {
                while !scanner.isAtEnd {
                    guard !Task.isCancelled else { return nil }
                    if let part = parser.parsePart(scanner: scanner) { parts.append(part) }
                }
            }
        }
        styled = !parts.isEmpty
        guard !Task.isCancelled else { return nil }
        if parts.isEmpty {
            parts = document.cues.map { SubtitlePart(Double($0.start) / 1_000_000, Double($0.end) / 1_000_000, $0.text) }
        }
        cues = parts.sorted { $0.start < $1.start }
        var latest = -Double.infinity
        reach = cues.map { latest = max(latest, $0.end); return latest }
    }
    func parts(at time: Double) -> [SubtitlePart] {
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        var index = low - 1, result: [SubtitlePart] = []
        while index >= 0, reach[index] > time {
            if cues[index].end > time { result.append(cues[index]) }
            index -= 1
        }
        return result.reversed()
    }
}

private struct KSPlaybackSubtitleCueSnapshot: Equatable {
    let identity: ObjectIdentifier
    let start: Double
    let end: Double
    let image: ObjectIdentifier?
    let origin: CGPoint
    let canvasSize: CGSize
    let animation: ASSAnimation

    init(_ part: SubtitlePart) {
        identity = ObjectIdentifier(part); start = part.start; end = part.end
        image = part.image.map(ObjectIdentifier.init); origin = part.origin
        canvasSize = part.canvasSize; animation = part.animation
    }
}

private struct KSPlaybackSubtitleOutputSnapshot: Equatable {
    let trackID: String?
    let pictureSize: CGSize
    let styled: Bool
    let cues: [KSPlaybackSubtitleCueSnapshot]

    init(trackID: String?, pictureSize: CGSize, styled: Bool, parts: [SubtitlePart]) {
        self.trackID = trackID; self.pictureSize = pictureSize; self.styled = styled
        cues = parts.map(KSPlaybackSubtitleCueSnapshot.init)
    }
}
struct KSPlaybackChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let start: Double
    var end: Double? = nil
}

/// The sole active iOS playback core. The facade keeps every consumer on the same
/// media identity and serializes seeks because FFmpeg accepts only one seek at a time.
@MainActor @Perceptible final class KSPlaybackEngine: NSObject, MediaPlayerDelegate {
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var bufferedPosition = 0.0
    private(set) var presentationSize = CGSize.zero
    private(set) var mediaID: String?
    private(set) var isReady = false
    private(set) var paused = true
    private(set) var buffering = false
    private(set) var hasPicture = false
    @PerceptionIgnored private(set) var hasPresentedPicture = false
    private(set) var tracks: [KSPlaybackTrack] = []
    private(set) var chapters: [KSPlaybackChapter] = []
    private(set) var subtitleLines: [String] = []
    private(set) var subtitleImages: [UIImage] = []
    private(set) var subtitleBitmaps: [KSPlaybackSubtitleBitmap] = []
    private(set) var subtitleStyledParts: [SubtitlePart] = []
    private(set) var secondarySubtitleLines: [String] = []
    private(set) var secondarySubtitleImages: [UIImage] = []
    private(set) var secondarySubtitleBitmaps: [KSPlaybackSubtitleBitmap] = []
    private(set) var secondarySubtitleStyledParts: [SubtitlePart] = []
    private(set) var bytesRead: Int64 = 0
    private(set) var bitrate: Double = 0
    private(set) var frameRate: Double = 0
    private(set) var droppedVideoFrames: UInt32 = 0
    private(set) var droppedVideoPackets: UInt32 = 0
    @PerceptionIgnored private var previousSamplePictureTime: Double?
    private(set) var decoder = "auto"
    private(set) var currentDecoder = "准备中"
    private(set) var usingSystemPlayer = false
    private(set) var videoSelection: String?
    private(set) var audioSelection: String?
    private(set) var subtitleSelection: String?
    private(set) var secondarySubtitleSelection: String? = "no"
    private(set) var subtitleDelay = 0.0
    private(set) var subtitleSourceTime = 0.0
    private(set) var secondarySubtitleSourceTime = 0.0
    private(set) var playbackInfo = PlaybackInfo()
    private(set) var videoBitDepth: Int?
    private(set) var audioDelay = 0.0
    private(set) var muted = false
    private(set) var volume: Float = 1
    var speed: Float = 1 { didSet { core?.playbackRate = min(8, max(0.25, speed)); synchronizePictureInPictureClock() } }
    var onUserSeek: ((Double) -> Void)?
    var onReady: (() -> Void)?
    var onTick: (() -> Void)?
    var onFinish: ((Error?) -> Void)?
    var onAudioServicesResume: ((KSAudioServicesResumeContext) -> Bool)?
    @PerceptionIgnored private var audioServicesGate = PlaybackUserResumeGate<KSAudioServicesResumeContext>()
    var requiresAudioServicesResume: Bool { audioServicesGate.context != nil }
    var audioServicesAvailable: Bool { audioServicesGate.available }
    var onReopenRequested: (() -> Void)?
    /// External and AI cues remain owned by the session; PiP samples them at the decoded frame time.
    var pictureInPictureSubtitleProvider: ((Double) -> (primary: PlayerSubtitlePresentation, secondary: PlayerSubtitlePresentation))?
    private(set) var renderingRevision = UUID()
    var renderView: UIView? { externalHost == nil ? core?.view : nil }
    var pipController: AVPictureInPictureController? { pipPresenter?.controller ?? core?.pipController }
    var pictureInPictureActive: Bool { pipController?.isPictureInPictureActive == true }
    var inputRevision: UUID { openID }
    var seeking: Bool { currentSeek != nil || pendingSeek != nil }
    var timelineRevision: Int { renderingTimeline }
    /// The first actual picture can arrive after a paused seek's completion.
    /// Publish only stopped-picture changes so an idle overlay can settle once.
    private(set) var stoppedPictureRevision = 0
    var selections: KSPlaybackSelections {
        var snapshot = KSPlaybackSelections(video: videoSelection, audio: audioSelection,
                                            subtitle: subtitleSelection, secondarySubtitle: secondarySubtitleSelection)
        for (kind, id) in pendingTrackSelections {
            switch kind {
            case .video: snapshot.video = id
            case .audio: snapshot.audio = id
            case .subtitle: snapshot.subtitle = id
            }
        }
        // The native route accepts one audio and one video track. Their AV track IDs
        // do not identify the corresponding FFmpeg streams after a fallback.
        if native != nil {
            if snapshot.video != "no" { snapshot.video = nil }
            if snapshot.audio != "no" { snapshot.audio = nil }
        }
        return snapshot
    }
    var startupMediaTime: Double? {
        guard let core else { return nil }
        let audioOnly = videoSelection == "no" || (!tracks.isEmpty && !tracks.contains { $0.kind == .video })
        let time = audioOnly ? position : (ffmpeg?.displayedVideoTime ?? (hasPicture ? core.currentPlaybackTime : .nan))
        return time.isFinite && time >= 0 ? time : nil
    }
    var seekable: Bool {
        core?.seekable == true || (native?.isReadyToPlay == true && duration > 0)
    }
    /// Direct picture time avoids a prefilling audio queue advancing danmaku ahead of the frame.
    var displayPosition: Double {
        guard videoSelection != "no", let core else { return position }
        let value = ffmpeg?.displayedVideoTime ?? core.currentPlaybackTime
        return value.isFinite && value >= 0 ? value : position
    }
    @PerceptionIgnored private var core: (any MediaPlayerProtocol)?
    private var ffmpeg: KSMEPlayer? { core as? KSMEPlayer }
    private var native: KSAVPlayer? { core as? KSAVPlayer }
    private(set) var systemFallback: String?
    private(set) var nativeDropCount: Int?
    private(set) var longestSubmissionGap = 0.0
    private(set) var longestSourceGap = 0.0
    @PerceptionIgnored private var readingNativeMetrics = false
    @PerceptionIgnored private var nativeStarted: TimeInterval?

    @PerceptionIgnored private var routeURL: URL?
    @PerceptionIgnored private var detectedContainer: String?

    func beginPlaybackRoute() { systemFallback = nil; routeURL = nil; detectedContainer = nil }

    private func fallbackToKS(_ reason: String) {
        guard native != nil, systemFallback == nil else { return }
        systemFallback = reason
        let opening = openID
        Task { @MainActor [weak self] in
            guard let self, self.openID == opening, self.native != nil, self.systemFallback != nil else { return }
            self.onReopenRequested?()
        }
    }
    @PerceptionIgnored private var pipPresenter: KSCompositedPictureInPicture?
    @PerceptionIgnored private var openID = UUID()
    @PerceptionIgnored private var options: KSOptions?
    @PerceptionIgnored private var suppliedChapters: [KSPlaybackChapter] = []
    @PerceptionIgnored private weak var observedPiP: AVPictureInPictureController?
    @PerceptionIgnored private var clock: Task<Void, Never>?
    @PerceptionIgnored private var thumbnailReader: PlaybackThumbnailReader?
    @PerceptionIgnored private weak var externalHost: UIView?
    @PerceptionIgnored private var detachedVideoTracks: [KSPlaybackTrack] = []
    @PerceptionIgnored private var audioOff = false
    @PerceptionIgnored private var defaultTracks: [String: String] = [:]
    @PerceptionIgnored private var subtitlePolicy = SubtitleTrackSelection()
    @PerceptionIgnored private var externalSubtitleDocuments: [String: KSExternalSubtitleDocument] = [:]
    @PerceptionIgnored private var externalSubtitleOrder: [String] = []
    @PerceptionIgnored private var pendingTrackSelections: [(KSPlaybackTrack.Kind, String?)] = []
    @PerceptionIgnored private var wantsPlaying = false
    @PerceptionIgnored private var failedVideo = false
    @PerceptionIgnored private var decoderDiagnosticCount = 0
    @PerceptionIgnored private var pictureWatchdog = PlaybackPictureWatchdog()
    @PerceptionIgnored private var startupStages = Set<String>()
    @PerceptionIgnored private var nextPlaybackInfoSample = 0.0
    @PerceptionIgnored private var lastStoppedPicture: Double?
    @PerceptionIgnored private var primarySubtitleOutputSnapshot: KSPlaybackSubtitleOutputSnapshot?
    @PerceptionIgnored private var secondarySubtitleOutputSnapshot: KSPlaybackSubtitleOutputSnapshot?
    #if DEBUG
    @PerceptionIgnored private var nextRenderDiagnostic = 0.0
    #endif
    @PerceptionIgnored private var seekSequence = 0
    // A suspended overlay must wake for a paused seek even when the sampled
    // position is unchanged. This changes only at explicit transport boundaries.
    private var renderingTimeline = 0
    private struct SeekRequest {
        let sequence: Int
        let time: Double
        let completion: (Bool) -> Void
    }
    @PerceptionIgnored private var currentSeek: SeekRequest?
    @PerceptionIgnored private var pendingSeek: SeekRequest?

    func open(url: URL, headers: [String: String], mediaID: String, format: String? = nil,
              discPlaylist: Int? = nil, startTime: Double = 0, isLive: Bool = false,
              audioURL: URL? = nil, audioHeaders: [String: String] = [:],
              cacheIOURL: URL? = nil, audioCacheIOURL: URL? = nil, selections: KSPlaybackSelections? = nil) {
        if routeURL != url { routeURL = url; detectedContainer = nil; systemFallback = nil }
        let previousVideoTracks = selections?.video == "no" ? tracks.filter { $0.kind == .video } : []
        shutdown()
        detachedVideoTracks = previousVideoTracks.map { value in
            var track = value
            track.selected = false
            return track
        }
        self.mediaID = mediaID
        if !audioServicesGate.available {
            let selection = selections ?? KSPlaybackSelections(video: nil, audio: nil, subtitle: nil, secondarySubtitle: "no")
            audioServicesGate.suspend(context: KSAudioServicesResumeContext(mediaID: mediaID, position: startTime,
                duration: 0, selections: selection), available: false)
            onFinish?(PlaybackAudioFailure.unavailable())
            return
        }
        openID = UUID(); let activeOpen = openID
        thumbnailReader = PlaybackThumbnailReader(url: cacheIOURL ?? url, headers: cacheIOURL == nil ? headers : [:])
        let options = KSPlaybackOptions()
        options.selections = selections
        options.videoDisable = selections?.video == "no"
        options.prefersTabletFrameQueue = UIDevice.current.userInterfaceIdiom == .pad
        options.preferredAudioTrackID = selections?.audio.flatMap(Int32.init)
        if let selections {
            videoSelection = selections.video; audioSelection = selections.audio
            subtitlePolicy.selectPrimary(selections.subtitle)
            subtitlePolicy.selectSecondary(selections.secondarySubtitle)
            subtitleSelection = subtitlePolicy.primary; secondarySubtitleSelection = subtitlePolicy.secondary
            audioOff = selections.audio == "no"
        }
        let soloAudioURL = options.videoDisable ? audioURL : nil
        let playbackURL = soloAudioURL ?? url
        options.appendHeader(soloAudioURL == nil || audioHeaders.isEmpty ? headers : audioHeaders)
        options.cacheIOURL = soloAudioURL == nil ? cacheIOURL : audioCacheIOURL
        options.companionAudioURL = options.videoDisable ? nil : audioURL
        options.companionAudioHeaders = audioHeaders.isEmpty ? headers : audioHeaders
        options.companionAudioCacheIOURL = audioCacheIOURL
        options.isAccurateSeek = true
        options.isSeekedAutoPlay = false
        options.registerRemoteControll = false
        options.preferredForwardBufferDuration = isLive ? 1 : 5
        options.isSecondOpen = true
        options.maxBufferDuration = 45
        // Native workers enter these callbacks before they can hop to the UI.
        // Sendable keeps that outer entry from inheriting MainActor isolation.
        options.onVideoDecoderChanged = { @Sendable [weak self] decoderName in
            Task { @MainActor [weak self] in
                guard let self, self.mediaID == mediaID, self.openID == activeOpen else { return }
                self.currentDecoder = decoderName
                self.refreshPlaybackInfo()
            }
        }
        options.onVideoDecoderFailed = { @Sendable [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.mediaID == mediaID, self.openID == activeOpen else { return }
                self.failVideo(message)
            }
        }
        options.onVideoDecoderError = { @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.mediaID == mediaID, self.openID == activeOpen,
                      self.decoderDiagnosticCount < 4 else { return }
                self.decoderDiagnosticCount += 1
                Diagnostics.shared.record(.warning, "player.decoder", "error=\(PlaybackFailureDiagnostics.codes(error)) \(self.failureDiagnostic)")
            }
        }
        options.hardwareDecode = decoder != "software"
        options.asynchronousDecompression = decoder != "software"
        options.autoDeInterlace = true
        options.videoDelay = -audioDelay
        options.startPlayTime = max(0, startTime)
        options.autoSelectEmbedSubtitle = true
        options.formatContextOptions["rw_timeout"] = 20_000_000
        if ["rtsp", "rtsps"].contains(url.scheme?.lowercased() ?? "") { options.formatContextOptions["rtsp_transport"] = "tcp" }
        if let discPlaylist { options.formatContextOptions["playlist"] = String(discPlaylist) }
        self.options = options
        let systemCandidate = SystemPlaybackRoute.accepts(url: url, format: format, live: isLive,
                                                          separateAudio: audioURL != nil, disc: discPlaylist != nil, demuxer: detectedContainer)
        let useNative = systemCandidate && decoder == "system" && systemFallback == nil && audioDelay == 0
            && selections?.video == nil && selections?.audio == nil
            && [nil, "no"].contains(selections?.subtitle) && [nil, "no"].contains(selections?.secondarySubtitle)
        let player: any MediaPlayerProtocol
        if useNative {
            let systemOptions = KSOptions()
            if cacheIOURL == nil { systemOptions.appendHeader(headers) }
            systemOptions.preferredForwardBufferDuration = options.preferredForwardBufferDuration
            systemOptions.isAccurateSeek = true
            let system = KSAVPlayer(url: cacheIOURL ?? url, options: systemOptions)
            player = system
            usingSystemPlayer = true
            currentDecoder = "系统 AVPlayer"
            nativeStarted = ProcessInfo.processInfo.systemUptime
        } else {
            player = KSMEPlayer(url: playbackURL, options: options)
        }
        let playerIdentity = ObjectIdentifier(player)
        core = player
        if let player = ffmpeg {
            if let output = player.videoOutput as? MetalPlayView, AVPictureInPictureController.isPictureInPictureSupported() {
                let presenter = KSCompositedPictureInPicture(engine: self, player: player)
                pipPresenter = presenter
                player.applicationPictureInPictureController = presenter.controller
                output.pictureInPictureFrame = { [weak self, weak player, weak presenter, weak output] buffer, timestamp in
                    guard let self, let player, let presenter, let output, self.core === player else { return false }
                    return presenter.submit(buffer, time: player.relativeVideoTime(for: timestamp),
                                            active: output.pictureInPictureActive)
                }
            }
            player.playbackCommand = { @Sendable [weak self] playing in
                Task { @MainActor [weak self] in
                    guard let self, let player = self.core,
                          ObjectIdentifier(player) == playerIdentity, self.openID == activeOpen else { return }
                    if playing { self.play() } else { self.pause() }
                }
            }
            player.seekCommand = { @Sendable [weak self] target in
                Task { @MainActor [weak self] in
                    guard let self, let player = self.core,
                          ObjectIdentifier(player) == playerIdentity, self.openID == activeOpen else { return }
                    self.seekFromUser(to: target)
                }
            }
        }
        player.delegate = self
        player.playbackRate = speed
        player.playbackVolume = volume
        player.isMuted = muted || audioOff
        player.view?.isHidden = videoSelection == "no"
        player.contentMode = .scaleAspectFit
        if let host = externalHost, let picture = player.view {
            picture.frame = host.bounds; picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(picture)
        }
        wantsPlaying = true; paused = false; buffering = true
        renderingRevision = UUID()
        player.prepareToPlay()
        let identity = mediaID
        clock = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player, self.core === player, self.mediaID == identity else { return }
                self.sample()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    func shutdown() {
        audioServicesGate.clearPending()
        PictureInPicture.shared.stop(engine: self)
        openID = UUID()
        if let output = ffmpeg?.videoOutput as? MetalPlayView {
            output.pictureInPictureFrame = nil; output.pictureInPictureActive = false
        }
        pipPresenter?.reset(); pipPresenter = nil
        ffmpeg?.applicationPictureInPictureController = nil
        clock?.cancel(); clock = nil
        thumbnailReader?.cancel(); thumbnailReader = nil
        let cancelled = [currentSeek, pendingSeek].compactMap { $0 }
        currentSeek = nil; pendingSeek = nil; seekSequence += 1; renderingTimeline &+= 1
        core?.delegate = nil; ffmpeg?.playbackCommand = nil; ffmpeg?.seekCommand = nil
        core?.pipController?.stopPictureInPicture(); observedPiP = nil
        core?.shutdown(); core?.view?.removeFromSuperview(); core = nil; options = nil
        failedVideo = false; decoderDiagnosticCount = 0; pictureWatchdog = PlaybackPictureWatchdog(); startupStages = []
        nextPlaybackInfoSample = 0
        nativeStarted = nil; nativeDropCount = nil; usingSystemPlayer = false
        longestSubmissionGap = 0; longestSourceGap = 0
        videoBitDepth = nil
        mediaID = nil; position = 0; duration = 0; bufferedPosition = 0
        lastStoppedPicture = nil
        isReady = false; paused = true; buffering = false; wantsPlaying = false; hasPicture = false
        hasPresentedPicture = false
        detachedVideoTracks = []
        externalSubtitleDocuments = [:]; externalSubtitleOrder = []
        tracks = []; chapters = []; clearSubtitleOutput(); presentationSize = .zero
        bytesRead = 0; bitrate = 0; frameRate = 0; audioOff = false
        droppedVideoFrames = 0; droppedVideoPackets = 0; previousSamplePictureTime = nil
        videoSelection = nil; audioSelection = nil; subtitleSelection = nil; secondarySubtitleSelection = "no"; subtitlePolicy = SubtitleTrackSelection(); pendingTrackSelections = []; defaultTracks = [:]; suppliedChapters = []; playbackInfo = PlaybackInfo(); currentDecoder = "准备中"
        renderingRevision = UUID()
        for request in cancelled { request.completion(false) }
    }
    func play() {
        guard audioServicesGate.available else { return }
        if let context = audioServicesGate.userResumeContext {
            wantsPlaying = true; paused = false
            if onAudioServicesResume?(context) == true { audioServicesGate.clearPending() }
            else { wantsPlaying = false; paused = true }
            return
        }
        guard !failedVideo else { return }
        wantsPlaying = true; paused = false
        if isReady, duration > 0, position >= duration - 0.1 {
            seek(to: 0)
        } else if currentSeek == nil { core?.play() }
        synchronizePictureInPictureClock()
    }
    func pause() { wantsPlaying = false; paused = true; core?.pause(); synchronizePictureInPictureClock() }
    func suspendForAudioServices(available: Bool) {
        let context = audioServicesGate.context ?? mediaID.map {
            KSAudioServicesResumeContext(mediaID: $0, position: position, duration: duration, selections: selections)
        }
        shutdown()
        audioServicesGate.suspend(context: context, available: available)
        if let context {
            mediaID = context.mediaID; position = context.position; duration = context.duration
            videoSelection = context.selections.video; audioSelection = context.selections.audio
            subtitlePolicy.selectPrimary(context.selections.subtitle)
            subtitlePolicy.selectSecondary(context.selections.secondarySubtitle)
            subtitleSelection = subtitlePolicy.primary; secondarySubtitleSelection = subtitlePolicy.secondary
            audioOff = context.selections.audio == "no"
        }
    }
    func resumeAfterForeground() {
        guard let core else { return }
        core.enterForeground()
        core.view?.setNeedsLayout()
        core.view?.layoutIfNeeded()
        sample()
    }
    func attachPictureInPicture(to view: UIView) { pipPresenter?.attach(to: view) }
    func detachPictureInPicture(from view: UIView) { pipPresenter?.detach(from: view) }
    func retainPictureInPictureSource() { pipPresenter?.retainSource() }
    func setPictureInPictureActive(_ active: Bool) {
        (ffmpeg?.videoOutput as? MetalPlayView)?.pictureInPictureActive = active
        pipPresenter?.refresh(active: active)
    }
    func preparePictureInPicture() { pipPresenter?.refresh(active: false) }
    private func synchronizePictureInPictureClock() {
        pipPresenter?.synchronizeClock(time: seeking ? position : displayPosition,
            rate: paused || buffering || seeking ? 0 : Double(speed))
    }
    func pictureInPictureSubtitles(at time: Double) -> (primary: PlayerSubtitlePresentation, secondary: PlayerSubtitlePresentation, style: SubtitleStyle) {
        if let ffmpeg { sampleSubtitles(ffmpeg, at: time) }
        let values = pictureInPictureSubtitleProvider?(time)
        return (values?.primary ?? PlayerSubtitlePresentation(lines: subtitleLines, styledParts: subtitleStyledParts,
                    sourceTime: subtitleSourceTime, bitmaps: subtitleBitmaps),
                values?.secondary ?? PlayerSubtitlePresentation(lines: secondarySubtitleLines, styledParts: secondarySubtitleStyledParts,
                    sourceTime: secondarySubtitleSourceTime, bitmaps: secondarySubtitleBitmaps), SubtitleStyle.load())
    }
    func setMuted(_ value: Bool) { muted = value; core?.isMuted = value || audioOff }
    func setVolume(_ value: Float) { volume = min(1, max(0, value)); core?.playbackVolume = volume }
    func setAudioDelay(_ value: Double) {
        guard value.isFinite else { return }
        audioDelay = min(10, max(-10, value)); options?.videoDelay = -audioDelay
        if audioDelay != 0 { fallbackToKS("音频偏移使用 KS") }
    }
    func setSubtitleDelay(_ value: Double) {
        guard value.isFinite else { return }
        subtitleDelay = min(60, max(-60, value))
        sample()
    }
    func setDecoder(_ value: String) {
        let next = ["software", "system"].contains(value) ? value : "auto"
        guard decoder != next else { return }
        systemFallback = nil; decoder = next; onReopenRequested?()
    }
    func setContentMode(_ mode: UIView.ContentMode) { core?.contentMode = mode }
    func showOnExternalDisplay(_ host: UIView?) {
        guard externalHost !== host else { return }
        core?.view?.removeFromSuperview(); externalHost = host
        if let host, let picture = core?.view {
            picture.frame = host.bounds; picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(picture)
        }
        renderingRevision = UUID()
    }
    func seekFromUser(to time: Double, completion: @escaping (Bool) -> Void = { _ in }) {
        if isReady, seekable, time.isFinite { onUserSeek?(min(max(0, time), duration)) }
        seek(to: time, completion: completion)
    }
    func seek(to requested: Double, completion: @escaping (Bool) -> Void = { _ in }) {
        guard requested.isFinite, core != nil, isReady, seekable else { completion(false); return }
        seekSequence += 1
        renderingTimeline &+= 1
        let target = min(max(0, requested), duration > 0 ? max(0, duration - 0.05) : max(0, requested))
        let request = SeekRequest(sequence: seekSequence, time: target, completion: completion)
        if let previous = pendingSeek { previous.completion(false) }
        pendingSeek = request
        clearSubtitleOutput()
        position = target
        pipPresenter?.invalidatePicture(at: target)
        if currentSeek == nil { performNextSeek() }
    }
    private func performNextSeek() {
        guard let request = pendingSeek, let player = core, let identity = mediaID else { return }
        let opening = openID, playerIdentity = ObjectIdentifier(player), sequence = request.sequence
        pendingSeek = nil; currentSeek = request
        Diagnostics.shared.record(.info, "player.seek", "stage=request sequence=\(sequence) target=\(request.time) native=\(Self.finite(player.currentPlaybackTime)) picture=\(Self.finite(displayPosition))")
        player.seek(time: request.time) { @Sendable [weak self] succeeded in
            Task { @MainActor [weak self] in
                guard let self, let player = self.core, ObjectIdentifier(player) == playerIdentity,
                      self.mediaID == identity, self.openID == opening,
                      let request = self.currentSeek, request.sequence == sequence else { return }
                self.currentSeek = nil
                let superseded = self.pendingSeek != nil
                Diagnostics.shared.record(.info, "player.seek", "stage=complete sequence=\(sequence) success=\(succeeded) superseded=\(superseded) target=\(request.time) native=\(Self.finite(player.currentPlaybackTime)) picture=\(Self.finite(self.displayPosition))")
                if !superseded {
                    self.position = Self.finite(player.currentPlaybackTime)
                    // The request epoch may have been drawn at the old picture
                    // time while the native seek was still in flight.
                    self.renderingTimeline &+= 1
                }
                request.completion(succeeded && !superseded)
                // Client completion can replace the media or begin another seek.
                // The old callback must not resume that seek's transport early.
                guard self.core === player, self.mediaID == identity, self.openID == opening, !self.failedVideo,
                      self.currentSeek == nil else { return }
                if self.pendingSeek != nil { self.performNextSeek() }
                else if !self.pendingTrackSelections.isEmpty { self.applyPendingTrackSelections() }
                else if self.wantsPlaying { player.play() }
                else { player.pause() }
                self.sample()
            }
        }
    }
    func selectVideo(id: String?) { select(.video, id: id) }
    func selectAudio(id: String?) { select(.audio, id: id) }
    func resolvedSubtitleSelection(_ target: SubtitleTrackSelection.Target) -> String? {
        guard let core else { return nil }
        let pair = resolvedSubtitleTracks(core)
        return target == .primary ? pair.primary : pair.secondary
    }
    func registerExternalSubtitle(_ document: SubtitleDocument, timing: SubtitleTiming) {
        guard core != nil else { return }
        if externalSubtitleDocuments[document.id] == nil { externalSubtitleOrder.append(document.id) }
        externalSubtitleDocuments[document.id] = KSExternalSubtitleDocument(document, timing: timing)
        clearSubtitleOutput(); refreshTracks(); onTick?()
    }
    func externalStyledParts(_ id: String, at time: Double) -> [SubtitlePart] {
        externalSubtitleDocuments[id]?.parts(at: time, styledOnly: true) ?? []
    }
    func removeExternalSubtitle(_ id: String) {
        guard externalSubtitleDocuments.removeValue(forKey: id) != nil else { return }
        externalSubtitleOrder.removeAll { $0 == id }
        if subtitlePolicy.primary == id { subtitlePolicy.selectPrimary("no") }
        if subtitlePolicy.secondary == id { subtitlePolicy.selectSecondary("no") }
        subtitleSelection = subtitlePolicy.primary; secondarySubtitleSelection = subtitlePolicy.secondary
        clearSubtitleOutput(); refreshTracks(); onTick?()
    }
    func setExternalSubtitleTiming(_ timing: SubtitleTiming) {
        for document in externalSubtitleDocuments.values { document.timing = timing }
        clearSubtitleOutput(); onTick?()
    }
    func selectSubtitle(id: String?) {
        guard core != nil else { return }
        subtitlePolicy.selectPrimary(id)
        subtitleSelection = subtitlePolicy.primary
        secondarySubtitleSelection = subtitlePolicy.secondary
        clearSubtitleOutput(); onTick?()
        select(.subtitle, id: subtitleSelection)
    }
    func selectSecondarySubtitle(id: String?) {
        guard core != nil else { return }
        subtitlePolicy.selectSecondary(id)
        subtitleSelection = subtitlePolicy.primary
        secondarySubtitleSelection = subtitlePolicy.secondary
        clearSubtitleOutput(); onTick?()
        select(.subtitle, id: subtitleSelection)
    }
    private func select(_ kind: KSPlaybackTrack.Kind, id: String?) {
        guard core != nil else { return }
        pendingTrackSelections.removeAll { $0.0 == kind }
        pendingTrackSelections.append((kind, id))
        if !seeking { applyPendingTrackSelections() }
    }
    private func applyPendingTrackSelections() {
        guard let player = core, !seeking else { return }
        if native != nil, pendingTrackSelections.contains(where: {
            ($0.0 == .subtitle && (subtitlePolicy.primary != nil && subtitlePolicy.primary != "no" || subtitlePolicy.secondary != nil && subtitlePolicy.secondary != "no")) ||
            ($0.0 == .video && $0.1 == "no")
        }) {
            fallbackToKS("所选轨道使用 KS")
            return
        }
        if let video = pendingTrackSelections.first(where: { $0.0 == .video }),
           (video.1 == "no") != (options?.videoDisable == true), onReopenRequested != nil {
            onReopenRequested?()
            return
        }
        let selections = pendingTrackSelections
        pendingTrackSelections = []
        var needsSeek = false
        let currentPosition = position
        for (kind, id) in selections {
            if kind == .subtitle {
                if let ffmpeg { needsSeek = applySubtitleDecoding(ffmpeg) || needsSeek }
                continue
            }
            let media: AVMediaType = kind == .video ? .video : .audio
            let candidates = player.tracks(mediaType: media)
            switch kind { case .video: videoSelection = id; case .audio: audioSelection = id; case .subtitle: break }
            if kind == .audio { audioOff = id == "no"; player.isMuted = muted || audioOff }
            if kind == .video { player.view?.isHidden = id == "no" }
            if id != "no", let selected = id.flatMap({ value in candidates.first { String($0.trackID) == value } })
                        ?? defaultTracks[kind.rawValue].flatMap({ value in candidates.first { String($0.trackID) == value } })
                        ?? candidates.first(where: { $0.isEnabled }) ?? candidates.first {
                // select requires a currently disabled track to switch decoder queues.
                if !selected.isEnabled {
                    if let ffmpeg { needsSeek = ffmpeg.selectTrackWithoutSeeking(track: selected) || needsSeek }
                    else { player.select(track: selected) }
                }
            }
        }
        refreshTracks()
        if needsSeek { seek(to: currentPosition) }
        else if wantsPlaying { player.play() }
        else { player.pause() }
    }
    private func sample() {
        if let native { sampleNative(native); return }
        guard let player = ffmpeg else { return }
        if !seeking { position = Self.finite(player.currentPlaybackTime) }
        duration = Self.finite(player.duration)
        bufferedPosition = max(position, Self.finite(player.playableTime))
        presentationSize = player.naturalSize
        hasPicture = player.videoOutput?.pixelBuffer != nil || (player.isReadyToPlay && (videoSelection == "no" || player.tracks(mediaType: .video).isEmpty))
        if hasPicture { hasPresentedPicture = true }
        isReady = player.isReadyToPlay
        buffering = wantsPlaying && !failedVideo && (player.loadState != .playable || player.isAudioInterrupted)
        paused = !wantsPlaying
        sampleStoppedPicture(player.displayedVideoTime)
        bytesRead = max(0, player.dynamicInfo?.bytesRead ?? 0)
        let sampleTime = ProcessInfo.processInfo.systemUptime
        // Decode bitrate and display FPS change on the native one-second window.
        // Keep the 50 ms picture/subtitle clock free of repeated format/track work.
        if sampleTime >= nextPlaybackInfoSample {
            nextPlaybackInfoSample = sampleTime + 1
            let statistics = player.dynamicInfo
            bitrate = Double((statistics?.audioBitrate ?? 0) + (statistics?.videoBitrate ?? 0))
            let pictureTime = player.displayedVideoTime
            frameRate = previousSamplePictureTime == pictureTime ? 0 : Self.finite(statistics?.displayFPS ?? 0)
            previousSamplePictureTime = pictureTime
            droppedVideoFrames = statistics?.droppedVideoFrameCount ?? 0
            droppedVideoPackets = statistics?.droppedVideoPacketCount ?? 0
            if let output = player.videoOutput as? MetalPlayView {
                longestSubmissionGap = output.longestSubmissionGap
                longestSourceGap = output.longestSourceGap
            }
            refreshPlaybackInfo()
        }
        #if DEBUG
        let diagnosticTime = ProcessInfo.processInfo.systemUptime
        if diagnosticTime >= nextRenderDiagnostic {
            nextRenderDiagnostic = diagnosticTime + 3
            let output = player.videoOutput
            let buffer = output?.pixelBuffer?.cvPixelBuffer
            var values: [Int] = []
            var pixelFormat: OSType = 0
            if let buffer {
                pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                let planar = CVPixelBufferIsPlanar(buffer)
                let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
                let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
                let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
                let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
                if let base, width > 0, height > 0, stride > 0 {
                    let depth = output?.pixelBuffer?.bitDepth ?? 8
                    for row in 1...4 { for column in 1...4 {
                        let x = min(width - 1, width * column / 5), y = min(height - 1, height * row / 5)
                        let pixel = base.advanced(by: y * stride)
                        if planar && depth > 8 { values.append(Int(pixel.assumingMemoryBound(to: UInt16.self)[x])) }
                        else if planar { values.append(Int(pixel.assumingMemoryBound(to: UInt8.self)[x])) }
                    } }
                }
            }
            let layer = output?.displayLayer
            let viewBounds = player.view?.bounds ?? .zero
            let windowBounds = player.view?.window?.bounds ?? .zero
            let layerBounds = layer?.bounds ?? .zero
            let minimum = values.min() ?? -1, maximum = values.max() ?? -1
            Diagnostics.shared.record(.debug, "player.render", "position=\(position) picture=\(player.displayedVideoTime) ready=\(player.isReadyToPlay) load=\(player.loadState) format=\(pixelFormat) buffer=\(buffer.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "none") luma16=\(minimum)...\(maximum) fps=\(frameRate) view=\(viewBounds) window=\(windowBounds) layer=\(layerBounds) layerState=\(layer?.status.rawValue ?? -1) layerError=\(layer?.error.map { ($0 as NSError).code } ?? 0) surfaceHidden=\(player.view?.isHidden ?? true)")
            Diagnostics.shared.record(.debug, "player.render", player.renderDiagnostic)
            let subtitlePair = resolvedSubtitleTracks(player)
            Diagnostics.shared.record(.debug, "player.subtitle", "selected=\(subtitlePair.primary ?? "none")/\(subtitlePair.secondary ?? "none") sampleTime=\(displayPosition - subtitleDelay) lines=\(subtitleLines.count)/\(secondarySubtitleLines.count) chars=\(subtitleLines.reduce(0) { $0 + $1.count }) \(player.subtitleDiagnostic)")
        }
        #endif
        if let options {
            for (stage, value) in [("open", options.openTime), ("streams", options.findTime), ("video-decode", options.decodeVideoTime)] where value > 0 {
                if startupStages.insert(stage).inserted {
                    Diagnostics.shared.record(.info, "player.startup", "stage=\(stage) elapsed=\(max(0, value - options.prepareTime))")
                }
            }
        }
        // A decoder producing zero frames never becomes loadState.playable, so
        // the deadline follows decode/input evidence, independently of buffering.
        if pictureWatchdog.update(now: ProcessInfo.processInfo.systemUptime, ready: isReady,
            selectedVideo: videoSelection != "no" && tracks.contains(where: { $0.kind == .video && $0.selected }),
            picture: hasPicture, playing: !paused && !player.isAudioInterrupted, seeking: seeking,
            decoderStarted: (options?.decodeVideoTime ?? 0) > 0 && (options?.readVideoTime ?? 0) > 0,
            bytes: bytesRead, position: position, inputEnded: player.hasReachedEndOfInput) {
            failVideo("视频没有输出可显示的画面，请切换解码方式或线路。")
        }
        let pip = pipController
        if observedPiP !== pip { observedPiP = pip; renderingRevision = UUID() }
        sampleSubtitles(player)
        synchronizePictureInPictureClock()
        onTick?()
        if pictureInPictureActive, !seeking, paused || buffering { pipPresenter?.refreshPaused() }
    }
    private func sampleNative(_ player: KSAVPlayer) {
        guard systemFallback == nil else { return }
        if !seeking { position = Self.finite(player.currentPlaybackTime) }
        duration = Self.finite(player.duration)
        bufferedPosition = max(position, Self.finite(player.playableTime))
        presentationSize = player.naturalSize
        hasPicture = player.playerLayer.isReadyForDisplay
        hasPresentedPicture = hasPresentedPicture || hasPicture
        isReady = player.isReadyToPlay
        paused = !wantsPlaying
        buffering = wantsPlaying && player.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let now = ProcessInfo.processInfo.systemUptime
        if paused || seeking { nativeStarted = now }
        if !hasPresentedPicture, wantsPlaying, !seeking, let nativeStarted, now - nativeStarted > 15 {
            fallbackToKS("系统播放器未送出首帧")
            return
        }
        if now >= nextPlaybackInfoSample {
            nextPlaybackInfoSample = now + 1
            if !readingNativeMetrics, let item = player.player.currentItem {
                readingNativeMetrics = true
                let reader = NativePlaybackLog(item), opening = openID
                Task { [weak self] in
                    let counts = await Task.detached(priority: .utility) { reader.counters() }.value
                    guard let self else { return }
                    self.readingNativeMetrics = false
                    guard self.openID == opening else { return }
                    self.nativeDropCount = counts.drops
                    self.bytesRead = counts.bytes
                }
            }
        }
        if hasPicture { sampleStoppedPicture(position) }
        onTick?()
    }

    private func sampleStoppedPicture(_ value: Double) {
        guard value.isFinite, value >= 0, lastStoppedPicture != value else { return }
        lastStoppedPicture = value
        guard paused || buffering || seeking else { return }
        stoppedPictureRevision &+= 1
    }
    private func resolvedSubtitleTracks(_ player: any MediaPlayerProtocol, available: [MediaPlayerTrack]? = nil) -> (primary: String?, secondary: String?) {
        let native = (available ?? player.tracks(mediaType: .subtitle)).map { String($0.trackID) }
        return subtitlePolicy.resolved(available: native + externalSubtitleOrder,
                                       preferred: defaultTracks[KSPlaybackTrack.Kind.subtitle.rawValue], automaticAvailable: native)
    }
    /// Bitmap streams must be enabled together; KS's exclusive track selector would switch the
    /// other subtitle off. Text streams intentionally stay decoded in KS and are filtered below.
    @discardableResult private func applySubtitleDecoding(_ player: KSMEPlayer) -> Bool {
        let pair = resolvedSubtitleTracks(player)
        let wanted = Set([pair.primary, pair.secondary].compactMap { $0 })
        options?.subtitlePrerollTrackIDs = Set(wanted.compactMap(Int32.init))
        var needsSeek = false
        for track in player.tracks(mediaType: .subtitle) {
            let enabled = wanted.contains(String(track.trackID))
            if enabled, !track.isEnabled, (track as? FFmpegAssetTrack)?.isImageSubtitle == true { needsSeek = true }
            track.isEnabled = enabled
        }
        return needsSeek
    }
    private func sampleSubtitles(_ player: KSMEPlayer, at frameTime: Double? = nil) {
        guard !seeking else { clearSubtitleOutput(); return }
        let pictureTime = frameTime ?? displayPosition
        let time = pictureTime - subtitleDelay
        let subtitleTracks = player.tracks(mediaType: .subtitle)
        let pair = resolvedSubtitleTracks(player, available: subtitleTracks)
        var primary: [SubtitlePart] = []
        var secondary: [SubtitlePart] = []
        var primaryTime = time, secondaryTime = time
        // Drain every decoded text stream, including hidden tracks. Retaining active cues in
        // the timed queue lets a newly selected track show its current line immediately.
        for track in subtitleTracks {
            guard let info = track as? any SubtitleInfo else { continue }
            let parts = info.search(for: time - info.delay)
            if info.subtitleID == pair.primary { primary = parts; primaryTime = time - info.delay }
            else if info.subtitleID == pair.secondary { secondary = parts; secondaryTime = time - info.delay }
        }
        // Primary external documents belong to SubtitleCues, which preserves its authored ASS
        // rendering and timing. Only the secondary external slot is rendered by this engine.
        if let id = pair.secondary, let external = externalSubtitleDocuments[id] {
            secondaryTime = Double(external.timing.source(at: pictureTime)) / 1_000_000
            secondary = external.parts(at: secondaryTime)
        }
        func bitmaps(_ parts: [SubtitlePart]) -> [KSPlaybackSubtitleBitmap] {
            parts.enumerated().compactMap { index, part in
                let canvas = part.canvasSize
                let validCanvas = canvas.width.isFinite && canvas.height.isFinite && canvas.width > 0 && canvas.height > 0
                return part.image.map { KSPlaybackSubtitleBitmap(id: index, image: $0, origin: part.origin,
                    canvasSize: validCanvas ? canvas : presentationSize) }
            }
        }
        func isASS(_ id: String?) -> Bool {
            if let id, let external = externalSubtitleDocuments[id] { return external.document.format.isStyled }
            guard let track = subtitleTracks.first(where: { String($0.trackID) == id }),
                  let codec = (track as? FFmpegAssetTrack)?.codecName.lowercased() else { return false }
            return codec == "ass" || codec == "ssa"
        }
        let primarySnapshot = KSPlaybackSubtitleOutputSnapshot(trackID: pair.primary, pictureSize: presentationSize,
                                                              styled: isASS(pair.primary), parts: primary)
        let secondarySnapshot = KSPlaybackSubtitleOutputSnapshot(trackID: pair.secondary, pictureSize: presentationSize,
                                                                styled: isASS(pair.secondary), parts: secondary)
        // A static ASS cue still needs its new in-range time when selected,
        // replaced, or sought. Re-publishing identical text's age at 20 Hz
        // otherwise rebuilds the complete picture overlay and attributed label.
        if primarySnapshot != primarySubtitleOutputSnapshot || primary.contains(where: { $0.animation.requiresContinuousTime }) {
            subtitleSourceTime = primaryTime
        }
        if secondarySnapshot != secondarySubtitleOutputSnapshot || secondary.contains(where: { $0.animation.requiresContinuousTime }) {
            secondarySubtitleSourceTime = secondaryTime
        }
        if primarySnapshot != primarySubtitleOutputSnapshot {
            subtitleLines = SubtitleStyle.lines(primary.compactMap { $0.text?.string })
            subtitleImages = primary.compactMap(\.image)
            subtitleBitmaps = bitmaps(primary)
            // KS SubtitlePart equality compares only start/end. A replacement
            // ASS cue can have the same times but a different styled text/image.
            if primarySnapshot.styled || !subtitleStyledParts.isEmpty {
                withMutation(keyPath: \.subtitleStyledParts) { subtitleStyledParts = primarySnapshot.styled ? primary : [] }
            }
            primarySubtitleOutputSnapshot = primarySnapshot
        }
        if secondarySnapshot != secondarySubtitleOutputSnapshot {
            secondarySubtitleLines = SubtitleStyle.lines(secondary.compactMap { $0.text?.string })
            secondarySubtitleImages = secondary.compactMap(\.image)
            secondarySubtitleBitmaps = bitmaps(secondary)
            if secondarySnapshot.styled || !secondarySubtitleStyledParts.isEmpty {
                withMutation(keyPath: \.secondarySubtitleStyledParts) { secondarySubtitleStyledParts = secondarySnapshot.styled ? secondary : [] }
            }
            secondarySubtitleOutputSnapshot = secondarySnapshot
        }
    }
    private func clearSubtitleOutput() {
        primarySubtitleOutputSnapshot = nil; secondarySubtitleOutputSnapshot = nil
        subtitleSourceTime = 0; secondarySubtitleSourceTime = 0
        subtitleLines = []; subtitleImages = []; subtitleBitmaps = []; subtitleStyledParts = []
        secondarySubtitleLines = []; secondarySubtitleImages = []; secondarySubtitleBitmaps = []; secondarySubtitleStyledParts = []
    }
    private func refreshTracks() {
        guard let player = core else { return }
        nextPlaybackInfoSample = 0
        let subtitleTracks = player.tracks(mediaType: .subtitle)
        if defaultTracks[KSPlaybackTrack.Kind.subtitle.rawValue] == nil,
           let first = subtitleTracks.first(where: { $0.isEnabled }) ?? subtitleTracks.first {
            defaultTracks[KSPlaybackTrack.Kind.subtitle.rawValue] = String(first.trackID)
        }
        if let ffmpeg { applySubtitleDecoding(ffmpeg) }
        let subtitlePair = resolvedSubtitleTracks(player)
        tracks = [(KSPlaybackTrack.Kind.video, AVMediaType.video), (.audio, .audio), (.subtitle, .subtitle)].flatMap { kind, media in
            player.tracks(mediaType: media).filter { track in
                kind != .video || (track as? FFmpegAssetTrack)?.isDolbyVisionEnhancementLayer != true
            }.map { track in
                KSPlaybackTrack(id: String(track.trackID), kind: kind, title: track.name,
                                codec: (track as? FFmpegAssetTrack)?.codecName,
                                language: track.languageCode,
                                selected: kind == .subtitle ? String(track.trackID) == subtitlePair.primary : track.isEnabled,
                                width: kind == .video && track.naturalSize.width > 0 ? Int(track.naturalSize.width) : nil,
                                height: kind == .video && track.naturalSize.height > 0 ? Int(track.naturalSize.height) : nil)
            }
        }
        if options?.videoDisable == true, !tracks.contains(where: { $0.kind == .video }) {
            tracks += detachedVideoTracks
        }
        tracks += externalSubtitleOrder.compactMap { id in
            guard let external = externalSubtitleDocuments[id] else { return nil }
            return KSPlaybackTrack(id: id, kind: .subtitle, title: external.document.name,
                                   codec: external.document.format.rawValue, language: external.document.language,
                                   selected: id == subtitlePair.primary)
        }
        chapters = suppliedChapters.isEmpty ? player.chapters.enumerated().map {
            KSPlaybackChapter(id: $0.offset, title: $0.element.title, start: $0.element.start,
                              end: $0.element.end > $0.element.start ? $0.element.end : nil)
        } : suppliedChapters
    }
    private func refreshPlaybackInfo() {
        guard let player = core else { return }
        let video = player.tracks(mediaType: .video).first { $0.isEnabled }
        videoBitDepth = (video as? FFmpegAssetTrack).map { Int($0.bitDepth) }.flatMap { $0 > 0 ? $0 : nil }
        let audio = player.tracks(mediaType: .audio).first { $0.isEnabled }
        var info = PlaybackInfo()
        info.width = Int(presentationSize.width.rounded()); info.height = Int(presentationSize.height.rounded())
        info.videoCodec = video?.formatDescription.map(CMFormatDescriptionGetMediaSubType)
        switch currentDecoder {
        case "VideoToolbox (hardware)": info.hardwareDecoding = true
        case "VideoToolbox (software)", "FFmpeg software": info.hardwareDecoding = false
        default: info.hardwareDecoding = nil
        }
        info.audioCodec = audio?.formatDescription.map(CMFormatDescriptionGetMediaSubType)
        info.dolbyVisionProfile = video?.dovi.map { Int($0.dv_profile) }
        // Media specifications describe the source; sampled presentation FPS
        // is telemetry and fluctuates even when the same source plays normally.
        let sourceFrameRate = video.map { Double($0.nominalFrameRate) }
        info.frameRate = sourceFrameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (frameRate.isFinite && frameRate > 0 ? frameRate : nil)
        if let format = video?.formatDescription {
            info.transferFunction = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        if let format = audio?.formatDescription, let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            info.sampleRate = description.mSampleRate; info.channels = Int(description.mChannelsPerFrame)
        }
        info.bitrate = bitrate > 0 ? bitrate : nil
        if info != playbackInfo { playbackInfo = info }
    }
    func thumbnail(at time: Double) async -> CGImage? {
        guard time.isFinite, time >= 0, let reader = thumbnailReader, let identity = mediaID else { return nil }
        let image = await reader.image(at: time)
        guard mediaID == identity, thumbnailReader === reader else { return nil }
        return image
    }
    func setDiscChapters(_ chapters: [KSPlaybackChapter]) {
        suppliedChapters = chapters
        if !chapters.isEmpty { self.chapters = chapters }
    }
    private static func finite(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    var failureDiagnostic: String {
        let layer = ffmpeg?.videoOutput?.displayLayer
        return "decoder=\(currentDecoder) ready=\(isReady) picture=\(hasPicture) everPicture=\(hasPresentedPicture) time=\(position) displayed=\(displayPosition) seeking=\(seeking) playing=\(wantsPlaying) bytes=\(bytesRead) size=\(presentationSize) layer=\(layer?.status.rawValue ?? -1) layerCode=\(layer?.error.map { ($0 as NSError).code } ?? 0)"
    }
    private func failVideo(_ message: String) {
        guard !failedVideo else { return }
        // Stop the failed output, retaining the viewer's transport intent for a
        // bounded decoder rebuild. An actual user pause still updates that intent.
        failedVideo = true; core?.pause(); buffering = false
        Diagnostics.shared.record(.error, "player.video", "decoder=\(currentDecoder) \(message)")
        onFinish?(KSPlaybackFailure(message: message))
    }
    private func owns(_ player: some MediaPlayerProtocol) -> Bool { core === player }
    func readyToPlay(player: some MediaPlayerProtocol) {
        guard owns(player) else { return }
        if let native {
            guard systemFallback == nil else { return }
            let video = native.tracks(mediaType: .video), audio = native.tracks(mediaType: .audio)
            let videoType = video.first?.formatDescription.map(CMFormatDescriptionGetMediaSubType)
            let audioType = audio.first?.formatDescription.map(CMFormatDescriptionGetMediaSubType)
            let asset = native.player.currentItem?.asset
            guard video.count == 1, audio.count == 1,
                  videoType == kCMVideoCodecType_HEVC || videoType == kCMVideoCodecType_H264 || videoType == 0x6865_7631, // hev1
                  audioType == kAudioFormatMPEG4AAC,
                  asset?.availableMediaCharacteristicsWithMediaSelectionOptions.contains(.legible) != true,
                  asset?.availableChapterLocales.isEmpty == true,
                  native.tracks(mediaType: .subtitle).isEmpty else {
                fallbackToKS("该文件的编码、字幕、章节或多轨需要 KS")
                return
            }
        }
        if ffmpeg != nil { detectedContainer = options?.formatName }
        isReady = true; refreshTracks()
        for track in tracks where track.selected && track.kind != .subtitle { defaultTracks[track.kind.rawValue] = track.id }
        sample()
        if usingSystemPlayer { refreshPlaybackInfo() }
        renderingRevision = UUID(); onReady?()
        if wantsPlaying, !seeking { core?.play() }
    }
    func changeLoadState(player: some MediaPlayerProtocol) { if owns(player) { sample() } }
    func changeBuffering(player: some MediaPlayerProtocol, progress: Int) { if owns(player) { sample() } }
    func playBack(player: some MediaPlayerProtocol, loopCount: Int) {}
    func finish(player: some MediaPlayerProtocol, error: Error?) {
        guard owns(player) else { return }
        if native != nil, error != nil { fallbackToKS("系统播放失败"); return }
        if error == nil { position = duration; wantsPlaying = false; paused = true; buffering = false }
        onFinish?(error)
    }
}
#endif
