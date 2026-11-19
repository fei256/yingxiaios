#if os(iOS)
import SwiftUI

private struct PlayerControlMinimumKey: EnvironmentKey { static let defaultValue: CGFloat = 48 }
private struct PlayerControlsTouchActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var playerControlMinimum: CGFloat {
        get { self[PlayerControlMinimumKey.self] }
        set { self[PlayerControlMinimumKey.self] = newValue }
    }
    var playerControlsTouchActive: Bool {
        get { self[PlayerControlsTouchActiveKey.self] }
        set { self[PlayerControlsTouchActiveKey.self] = newValue }
    }
}

struct PlayerControlHitFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

/// Both player rows use the same unplated symbols, hit targets and selected feedback.
struct PlayerToolbarButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.playerControlMinimum) private var minimum
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(minWidth: minimum, minHeight: minimum)
            .foregroundStyle(.white.opacity(enabled ? 0.96 : 0.3))
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.2) : Color.white.opacity(configuration.isPressed ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
    }
}

extension View {
    /// Publish window coordinates so the native picture layer leaves these touches to SwiftUI.
    func playerControlHitRegion() -> some View { modifier(PlayerControlHitRegion()) }
    /// Expand the actual Button label, so iOS 16's hit testing includes the
    /// space around an unplated symbol as well as the visible glyph.
    func playerControlTarget(_ size: CGFloat? = nil) -> some View {
        modifier(PlayerControlTarget(size: size))
    }
}

private struct PlayerControlTarget: ViewModifier {
    @Environment(\.playerControlMinimum) private var minimum
    let size: CGFloat?
    func body(content: Content) -> some View {
        content
            .frame(minWidth: max(44, size ?? minimum), minHeight: max(44, size ?? minimum))
            .background(Color.white.opacity(0.001))
            .contentShape(.interaction, Rectangle())
            .playerControlHitRegion()
    }
}

private struct PlayerControlHitRegion: ViewModifier {
    @Environment(\.playerControlsTouchActive) private var active
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(key: PlayerControlHitFrames.self, value: active ? [geometry.frame(in: .global)] : [])
            }.allowsHitTesting(false)
        }
    }
}

#endif
