#if os(iOS)
import SwiftUI

/// Both player rows use the same unplated symbols, hit targets and selected feedback.
struct PlayerToolbarButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(minWidth: 48, minHeight: 48)
            .foregroundStyle(.white.opacity(enabled ? 0.96 : 0.3))
            .background(selected ? Color.accentColor.opacity(0.2) : Color.white.opacity(configuration.isPressed ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

extension View {
    /// Expand the actual Button label, so iOS 16's hit testing includes the
    /// space around an unplated symbol as well as the visible glyph.
    func playerControlTarget(_ size: CGFloat = 48) -> some View {
        frame(minWidth: max(44, size), minHeight: max(44, size)).contentShape(Rectangle())
    }
}

#endif
