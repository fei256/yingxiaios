import SwiftUI

/// The library and searches share the reference's quiet blue and teal palette.
struct LibraryAtmosphere: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.098, green: 0.122, blue: 0.208),
                                        Color(red: 0.133, green: 0.220, blue: 0.259)],
                               startPoint: .leading, endPoint: .trailing)
                RadialGradient(colors: [Color(red: 0.34, green: 0.28, blue: 0.62).opacity(0.20), .clear],
                               center: .init(x: 0.24, y: 0.20), startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.65)
                RadialGradient(colors: [Color(red: 0.16, green: 0.43, blue: 0.46).opacity(0.16), .clear],
                               center: .init(x: 0.94, y: 0.60), startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.75)
            }
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder func libraryBackdrop() -> some View {
        #if os(iOS)
        background { LibraryAtmosphere() }.libraryAppearance()
        #else
        screenBackdrop()
        #endif
    }
    @ViewBuilder func libraryAppearance() -> some View {
        #if os(iOS)
        environment(\.colorScheme, .dark).foregroundStyle(.white)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}
