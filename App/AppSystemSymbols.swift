/// Keep icon-only controls visible on iOS 16 while retaining newer artwork
/// on systems that include it. The aliases preserve each control's meaning.
enum AppSystemSymbols {
    static func name(_ name: String) -> String {
        if #unavailable(iOS 18, macOS 15, tvOS 18) {
            switch name {
            case "airplay.video": return "airplayvideo"
            case "wand.and.sparkles": return "wand.and.stars"
            default: break
            }
        }
        if #unavailable(iOS 17, macOS 14, tvOS 17) {
            switch name {
            case "arrow.down.circle.dotted": return "arrow.down.circle"
            case "bubble.left.and.text.bubble.right": return "bubble.left.and.bubble.right"
            case "bubble.left.and.text.bubble.right.fill": return "bubble.left.and.bubble.right.fill"
            case "exclamationmark.magnifyingglass": return "magnifyingglass"
            case "gauge.with.dots.needle.67percent": return "speedometer"
            default: break
            }
        }
        return name
    }
}
