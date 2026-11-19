#if os(iOS)
import SwiftUI

private struct PlayerControlMinimumKey: EnvironmentKey { static let defaultValue: CGFloat = 48 }
extension EnvironmentValues {
    var playerControlMinimum: CGFloat {
        get { self[PlayerControlMinimumKey.self] }
        set { self[PlayerControlMinimumKey.self] = newValue }
    }
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
    }
}

#endif
