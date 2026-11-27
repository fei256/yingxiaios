import SwiftUI
import TVCore

struct LocalCatalogDetailTitle: View {
    @AppStorage(TMDBServiceSettings.titleLogoKey) private var showTitleLogo = true
    let title: String
    let logo: URL?
    let width: CGFloat
    var centered = false
    @State private var logoAspect: CGFloat?
    var body: some View {
        Group {
            if showTitleLogo, let logo {
                TMDBArtwork(url: logo, maxPixels: 1000, fill: false, aspect: $logoAspect)
                    .frame(width: min(width * 0.70, centered ? 260 : 300), height: centered ? 92 : 84)
                    .overlay { if logoAspect == nil { titleText } }
                    .id(logo)
            } else { titleText }
        }.frame(maxWidth: .infinity, minHeight: 76, alignment: centered ? .center : .leading)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
    private var titleText: some View {
        Text(title).font(.system(size: width >= 700 ? 34 : 30, weight: .semibold))
            .multilineTextAlignment(centered ? .center : .leading).lineLimit(2).minimumScaleFactor(0.7)
    }
}
