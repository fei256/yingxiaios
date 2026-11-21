import Foundation

public enum LocalDanmakuPreferences {
    public static let builtinKey = "danmakuBuiltinEnabled"
    public static let changed = Notification.Name("LocalDanmakuConfigurationChanged")
    public static func enabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: "danmakuEnabled") as? Bool ?? true }
    public static func builtinEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: builtinKey) as? Bool ?? true }
    public struct Snapshot: Equatable, Sendable {
        public let enabled: Bool, automatic: Bool
        public let opacity: Double, fontSize: Double
    }
    public static func load(defaults: UserDefaults = .standard) -> Snapshot {
        let opacity = defaults.object(forKey: DanmakuStyle.opacityKey) as? Double ?? DanmakuStyle.standardOpacity
        let size = defaults.object(forKey: DanmakuStyle.fontSizeKey) as? Double ?? DanmakuStyle.standardFontSize
        return Snapshot(enabled: enabled(defaults: defaults),
            automatic: defaults.object(forKey: "danmakuAutoMatch") as? Bool ?? true,
            opacity: opacity.isFinite ? min(1, max(0, opacity)) : DanmakuStyle.standardOpacity,
            fontSize: size.isFinite ? min(64, max(12, size)) : DanmakuStyle.standardFontSize)
    }
    @MainActor public static func restored() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
    public static func hasBuiltin(_ raw: [String: JSONValue]) -> Bool {
        for key in ["danmaku", "danmu", "danmu_api", "danmaku_api", "danmuSearchUrl"] {
            guard let value = raw[key] else { continue }
            switch value {
            case .string(let value): if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            case .array(let value): if !value.isEmpty { return true }
            case .object(let value): if !value.isEmpty { return true }
            default: break
            }
        }
        return ["video", "data", "config"].contains { key in raw[key]?.object.map(hasBuiltin) ?? false }
    }
}
