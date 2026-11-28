import Foundation

/// Files whose tracks can be checked by AVFoundation without opening a second source connection.
public enum SystemPlaybackRoute {
    public static func accepts(url: URL, format: String?, live: Bool, separateAudio: Bool, disc: Bool,
                               demuxer: String? = nil) -> Bool {
        guard !live, !separateAudio, !disc,
              url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if let demuxer, !demuxer.isEmpty {
            return demuxer.split(separator: ",").contains("mp4")
        }
        let container = format?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let type = container.isEmpty ? url.pathExtension.lowercased() : container
        return ["mp4", "m4v", "mov", "video/mp4", "video/quicktime", "video/x-m4v"].contains(type)
    }
}
