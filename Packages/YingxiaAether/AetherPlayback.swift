import AVKit
import UIKit
import Combine
internal import AetherEngine

/// The app links only this dynamic framework. Keep package and FFmpeg types inside it.
@MainActor
public final class AetherPlayback: NSObject {
    public struct Track {
        public let id: Int
        public let name: String
        public let codec: String
        public let language: String?
        public let preferred: Bool

        fileprivate init(_ track: TrackInfo) {
            id = track.id
            name = track.name
            codec = track.codec
            language = track.language
            preferred = track.isDefault
        }
    }

    public struct Bitmap {
        public let id: Int
        public let image: CGImage
        public let origin: CGPoint
        public let canvas: CGSize
    }

    private let engine: AetherEngine
    private let surface = AetherPlayerView(frame: .zero)
    private var seekObserver: AnyCancellable?
    private var seekTask: Task<Void, Never>?
    private weak var pipLayer: CALayer?
    private weak var previousHost: UIView?
    private var stopped = false
    public private(set) var pipController: AVPictureInPictureController?
    public var onSetPlaying: ((Bool) -> Void)?
    public var onSkip: ((Double, @escaping (Bool) -> Void) -> Void)?
    public var view: UIView { surface }
    public var time: Double { engine.currentTime }
    public var sourceTime: Double { engine.sourceTime }
    public var duration: Double { engine.duration }
    public var buffered: Double { engine.bufferedPosition }
    public var ready: Bool { engine.isSessionReady }
    public var buffering: Bool { engine.isBuffering || engine.state == .loading }
    public var hasPicture: Bool { engine.hasFirstFrameReadyForDisplay || (ready && engine.videoRoute == .audio) }
    public var systemPlaying: Bool? {
        switch engine.state {
        case .playing: return true
        case .paused: return false
        default: return nil
        }
    }
    public var ended: Bool { engine.state == .ended }
    public var failure: String? {
        if case .error(let message) = engine.state { return message }
        return engine.audioDelivery == .droppedNoPipeline ? "Aether 无法播放此音轨" : nil
    }
    public var size: CGSize {
        let source = CGSize(width: CGFloat(engine.sourceVideoWidth), height: CGFloat(engine.sourceVideoHeight))
        return source.width > 0 ? source : engine.currentAVPlayerItem?.presentationSize ?? .zero
    }
    public var decoder: String { engine.activeVideoDecoder ?? engine.videoRoute.rawValue }
    public var audioTracks: [Track] { engine.audioTracks.map(Track.init) }
    public var subtitleTracks: [Track] { engine.subtitleTracks.map(Track.init) }
    public var activeAudio: Int? { engine.activeAudioTrackIndex }
    public var chapters: [(id: Int, title: String, start: Double, end: Double)] {
        engine.mediaChapters.map { ($0.id, $0.name, $0.startSeconds, $0.startSeconds + $0.durationSeconds) }
    }
    public private(set) var frameRate: Double?
    public private(set) var videoCodec: String?

    public static func make() throws -> AetherPlayback { try AetherPlayback(engine: AetherEngine()) }

    private init(engine: AetherEngine) {
        self.engine = engine
        super.init()
        engine.bind(view: surface)
    }

    public func load(url: URL, headers: [String: String], live: Bool, hls: Bool, audio: Int32?) async throws {
        var options = LoadOptions()
        options.httpHeaders = headers
        options.isLive = live
        options.nativeRemoteHLS = hls && !url.isFileURL
        options.prepareNativeSubtitles = true
        options.autoplay = false
        let probe = try await engine.load(url: url, options: options, audioSourceStreamIndex: audio)
        if stopped {
            engine.stop(resetDisplayCriteria: false, finalTeardown: false)
            throw CancellationError()
        }
        try Task.checkCancellation()
        frameRate = probe?.videoFrameRate
        videoCodec = probe?.videoCodecName
        let ksCodecs = ["avs2", "avs3", "av3a", "libtvav3a", "libdavs2", "libuavs3d"]
        if ksCodecs.contains(videoCodec?.lowercased() ?? "") || engine.audioTracks.contains(where: { ksCodecs.contains($0.codec.lowercased()) }) {
            throw NSError(domain: "YingxiaAether", code: 1, userInfo: [NSLocalizedDescriptionKey: "此片源需要映匣的定制解码器"])
        }
    }

    public func stop() {
        stopped = true
        seekObserver = nil
        seekTask?.cancel()
        pipController?.stopPictureInPicture()
        engine.unbind(view: surface)
        engine.stop()
        surface.removeFromSuperview()
    }

    public func play(rate: Float) { engine.play(); engine.setRate(rate) }
    public func pause() { engine.pause() }
    public func setVolume(_ volume: Float) { engine.volume = volume }
    public func setAudioDelay(_ delay: Double) { engine.setAudioDelay(delay) }
    public func selectAudio(_ index: Int) { engine.selectAudioTrack(index: index) }
    public func selectSubtitle(_ index: Int?, secondary: Bool) {
        if secondary {
            if let index { engine.selectSecondarySubtitleTrack(index: index) } else { engine.clearSecondarySubtitle() }
        } else {
            if let index { engine.selectSubtitleTrack(index: index) } else { engine.clearSubtitle() }
        }
    }

    public func subtitles(secondary: Bool, delay: Double) -> (lines: [String], bitmaps: [Bitmap]) {
        let time = sourceTime - delay
        let cues = secondary ? engine.secondarySubtitleCues : engine.subtitleCues
        var lines: [String] = [], images: [Bitmap] = []
        for cue in cues where cue.startTime <= time && time < cue.endTime {
            if let text = cue.text { lines.append(text) }
            if case .image(let image) = cue.body {
                let canvas = image.canvasSize == .zero ? size : image.canvasSize
                let origin = CGPoint(x: image.position.minX * canvas.width, y: image.position.minY * canvas.height)
                images.append(Bitmap(id: cue.id, image: image.cgImage, origin: origin, canvas: canvas))
            }
        }
        return (lines, images)
    }

    public func seek(to target: Double, completion: @escaping (Bool) -> Void) {
        var seekID: UInt64?
        seekObserver = engine.seekEvents.sink { [weak self] event in
            guard let self, !self.stopped, event.origin != .nativeScrub else { return }
            switch event.outcome {
            case .began:
                if abs(event.target - target) < 0.1 { seekID = event.id }
                return
            case .rejected: guard abs(event.target - target) < 0.1 else { return }
            default: guard event.id == seekID else { return }
            }
            self.seekObserver = nil
            if case .landed = event.outcome { completion(true) } else { completion(false) }
        }
        seekTask = Task { [weak self] in
            guard let self, !self.stopped else { return }
            await self.engine.seek(to: target)
        }
    }

    public func setContentMode(_ mode: UIView.ContentMode) {
        surface.contentMode = mode
        engine.videoGravity = mode == .scaleAspectFill ? .resizeAspectFill : mode == .scaleToFill ? .resize : .resizeAspect
    }
    public func retainPiPSurface() {
        guard let host = surface.superview, let window = host.window, host !== window else { return }
        let frame = surface.convert(surface.bounds, to: window)
        previousHost = host
        window.insertSubview(surface, at: 0)
        surface.frame = frame
    }
    public func setPiPActive(_ active: Bool) {
        guard engine.pictureInPictureActive != active else { return }
        engine.pictureInPictureActive = active
        if engine.nativeSubtitleRenditionsServed { engine.setNativeSubtitleRendering(active) }
        if !active {
            if surface.superview is UIWindow, let host = previousHost, host.window != nil {
                host.addSubview(surface)
                host.setNeedsLayout()
            }
            previousHost = nil
        }
    }
    public func updatePiPController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let layer = (engine.nativePlayerLayer as CALayer?) ?? engine.softwarePiPSource?.layer
        guard layer !== pipLayer else { return }
        pipLayer = layer
        if let layer = engine.nativePlayerLayer {
            pipController = AVPictureInPictureController(playerLayer: layer)
        } else if let source = engine.softwarePiPSource {
            pipController = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: self))
        } else {
            pipController = nil
        }
    }
}

extension AetherPlayback: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) { onSetPlaying?(playing) }
    public func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        engine.softwarePiPSource?.timeRange() ?? .invalid
    }
    public func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        engine.softwarePiPSource?.isPaused ?? true
    }
    public func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    public func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime) async {
        guard let onSkip else { return }
        await withCheckedContinuation { (reply: CheckedContinuation<Void, Never>) in
            onSkip(interval.seconds) { _ in reply.resume() }
        }
    }
}
