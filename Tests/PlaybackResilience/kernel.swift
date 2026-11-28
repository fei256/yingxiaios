import Foundation

@main struct KernelRoutingChecks {
    static func main() {
        let cases: [(String, String?, Bool, Bool, Bool)] = [
            ("https://example.com/movie.mkv", nil, false, false, true),
            ("file:///video.mp4", nil, false, false, true),
            ("https://example.com/live", "application/vnd.apple.mpegurl", false, false, true),
            ("https://example.com/video.mp4", nil, true, false, false),
            ("https://example.com/title.ts", nil, false, true, false),
            ("https://example.com/title.MPD?token=test", nil, false, false, false),
            ("https://example.com/play", "Application/Dash+XML; charset=utf-8", false, false, false),
            ("rtsp://example.com/live", nil, false, false, false),
            ("rtmp://example.com/live", nil, false, false, false),
            ("udp://example.com:1234", nil, false, false, false),
            ("file:///movie.iso", nil, false, false, false),
            ("https://example.com/play", "avs3", false, false, false),
        ]
        for (address, format, audio, disc, expected) in cases {
            let url = URL(string: address)!
            precondition(PlaybackKernel.aether.supports(url: url, format: format, separateAudio: audio, disc: disc) == expected)
            precondition(PlaybackKernel.ksPlayer.supports(url: url, format: format, separateAudio: audio, disc: disc))
        }
    }
}
