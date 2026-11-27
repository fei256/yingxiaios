import SwiftUI

#if os(iOS)
import UIKit

enum LocalSettingsAppearance {
    static let maximumWidth: CGFloat = 960
    static let cornerRadius: CGFloat = 24
    static let rowHeight: CGFloat = 60
    static let rowInset: CGFloat = 18
    static let iconWidth: CGFloat = 30
    static let groupSpacing: CGFloat = 24
}

private struct LocalSettingsAtmosphereKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var localSettingsAtmosphere: Bool {
        get { self[LocalSettingsAtmosphereKey.self] }
        set { self[LocalSettingsAtmosphereKey.self] = newValue }
    }
}

struct LocalSettingsAtmosphere: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: scheme == .dark ? [
            Color(red: 0.28, green: 0.17, blue: 0.25),
            Color(red: 0.16, green: 0.17, blue: 0.23),
            Color(red: 0.09, green: 0.17, blue: 0.20)
        ] : [
            Color(red: 0.96, green: 0.91, blue: 0.94),
            Color(red: 0.93, green: 0.94, blue: 0.97),
            Color(red: 0.88, green: 0.95, blue: 0.96)
        ], startPoint: .leading, endPoint: .trailing)
        .ignoresSafeArea().allowsHitTesting(false)
    }
}

private struct LocalSettingsSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    let radius: CGFloat
    let navigation: Bool

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                Group {
                    if opaque { shape.fill(Color(uiColor: .secondarySystemGroupedBackground)) }
                    else if navigation {
                        shape.fill(.ultraThinMaterial)
                            .overlay { shape.fill(dark ? Color(white: 0.19).opacity(0.56) : Color.white.opacity(0.10)) }
                    } else { shape.fill(Color.white.opacity(dark ? 0.065 : 0.55)) }
                }
                .shadow(color: .black.opacity(navigation ? (dark ? 0.18 : 0.08) : 0), radius: 12, y: 4)
                .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(dark ? (navigation ? 0.18 : 0.06) : 0.3), lineWidth: navigation ? 0.75 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

struct LocalHomeChoiceLabel: View {
    let title: String
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.body).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Color.primary.opacity(selected ? 0.13 : 0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func localSettingsCanvas() -> some View {
        background { LocalSettingsAtmosphere() }.environment(\.localSettingsAtmosphere, true)
    }

    func localSettingsSurface(cornerRadius: CGFloat = LocalSettingsAppearance.cornerRadius, navigation: Bool = false) -> some View {
        modifier(LocalSettingsSurface(radius: cornerRadius, navigation: navigation))
    }
}
#endif
