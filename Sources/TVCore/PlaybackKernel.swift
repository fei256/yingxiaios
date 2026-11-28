import Foundation

public enum PlaybackKernel: String, CaseIterable, Sendable {
    case ksPlayer, aether
    public static let preferenceKey = "local.playback.kernel"
    public var title: String { self == .aether ? "AetherEngine 6.89.1" : "KSPlayer" }

    public func supports(url: URL, format: String?, separateAudio: Bool, disc: Bool) -> Bool {
        guard self == .aether else { return true }
        guard !disc, !separateAudio, ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let ksFormats = ["mpd", "dash", "application/dash+xml", "iso", "bdmv", "avs2", "avs3", "av3a", "vvc", "h266"]
        let mime = (format ?? "").components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        return !ksFormats.contains(mime) && !ksFormats.contains(url.pathExtension.lowercased())
    }
}
