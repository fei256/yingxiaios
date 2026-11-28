import SwiftUI
import Perception
import TVCore

#if os(iOS)
struct CatalogDetailScrollOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The artwork fades into its sampled surface so the hero and episode rail share one canvas.
struct CatalogDetailBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let paint: DiscoverPaint?
    let width: CGFloat
    let heroHeight: CGFloat
    var scrollY: CGFloat = 0
    var trailer: TMDBMatch.Trailer? = nil
    var playsTrailer = false
    @State private var videoReady = false
    private var showsTrailer: Bool { playsTrailer && !reduceMotion }

    var body: some View {
        ZStack(alignment: .top) {
            (paint?.color ?? Color(white: 0.22)).ignoresSafeArea()
            if let paint {
                artwork(paint)
                    .id(ObjectIdentifier(paint.image)).transition(.opacity)
                    .opacity(showsTrailer && videoReady ? 0 : 1)
                    .frame(width: width, height: heroHeight)
                    .scaleEffect(reduceMotion ? 1 : 1 + max(0, -scrollY) / max(heroHeight, 1), anchor: .top)
                    .offset(y: reduceMotion ? 0 : -max(0, scrollY) * 0.28)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.62),
                            .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .frame(width: width, height: heroHeight, alignment: .top).clipped()
            }
            if let trailer, showsTrailer {
                DiscoverTrailer(trailer: trailer) { ready in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { videoReady = ready }
                }
                .frame(width: width, height: heroHeight).clipped()
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.18),
                        .init(color: (paint?.color ?? Color(white: 0.22)).opacity(0.75), location: 0.57),
                        .init(color: paint?.color ?? Color(white: 0.22), location: 0.85),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .offset(y: reduceMotion ? 0 : -max(0, scrollY) * 0.28)
                .opacity(videoReady ? 1 : 0)
                .frame(width: width, height: heroHeight, alignment: .top).clipped()
            }
        }
        .detailArtworkToolbarShade()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: paint.map { ObjectIdentifier($0.image) })
        .appOnChange(of: trailer?.key) { _, _ in videoReady = false }
        .appOnChange(of: showsTrailer) { _, plays in if !plays { videoReady = false } }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private func artwork(_ paint: DiscoverPaint) -> some View {
        if paint.image.width >= paint.image.height {
            Image(decorative: paint.image, scale: 1).resizable().scaledToFill()
                .frame(width: width, height: heroHeight, alignment: .top)
        } else {
            ZStack(alignment: .topTrailing) {
                Image(decorative: paint.image, scale: 1).resizable().scaledToFill()
                    .frame(width: width, height: heroHeight).blur(radius: 32)
                    .overlay(paint.color.opacity(0.35))
                Image(decorative: paint.image, scale: 1).resizable().scaledToFit()
                    .frame(width: min(width, heroHeight * CGFloat(paint.image.width) / CGFloat(paint.image.height)),
                           height: heroHeight)
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .black, location: 0.18),
                                               .init(color: .black, location: 0.88),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .padding(.trailing, width >= 700 ? width * 0.12 : 0)
            }.frame(width: width, height: heroHeight).clipped()
        }
    }
}

struct CatalogDetailHero<Identity: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let size: CGSize
    @ViewBuilder let identity: () -> Identity
    @ViewBuilder let actions: () -> Actions

    private var wide: Bool { CatalogDetailLayout.usesWideHero(in: size) && !typeSize.isAccessibilitySize }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: CatalogDetailLayout.identityTopInset(in: size))
                if wide {
                    HStack(alignment: .bottom, spacing: 24) {
                        identity().frame(maxWidth: .infinity, alignment: .center)
                        actions().frame(width: CatalogDetailLayout.actionsWidth(in: size.width, wide: true), alignment: .trailing)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) { identity(); actions() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CatalogEpisodeHeader<Sources: View, DetailTools: View, EpisodeTools: View>: View {
    let count: Int
    let sources: Sources
    let detailTools: DetailTools
    let episodeTools: EpisodeTools

    var body: some View {
        let titleAndSources = HStack(spacing: 12) {
            Text("剧集 · \(count)").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
            sources.frame(minWidth: 110, idealWidth: 110, maxWidth: .infinity)
        }
        let tools = HStack(spacing: 4) { detailTools; episodeTools }.fixedSize()
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { titleAndSources; tools }
            VStack(alignment: .trailing, spacing: 4) { titleAndSources; tools }
            VStack(alignment: .trailing, spacing: 4) { titleAndSources; detailTools; episodeTools }
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

struct CatalogPlaybackLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let loading: Bool

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small).tint(.black) }
                else { Image(systemName: symbol).font(.system(size: 19, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.black.opacity(0.58)).lineLimit(1)
            }
        }
    }
}

struct CatalogDetailToolStrip<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @ViewBuilder let content: () -> Content

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) { content() }
                .font(.system(size: 19, weight: .regular)).foregroundStyle(.white.opacity(0.9))
                .buttonStyle(.plain)
                .background {
                    if opaque { Capsule().fill(Color(white: 0.26)) }
                    else { Capsule().fill(.ultraThinMaterial).overlay { Capsule().fill(.white.opacity(0.04)) } }
                }
                .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75).allowsHitTesting(false) }
                .clipShape(Capsule())
        }
    }
}

struct CatalogDetailActionRow<Primary: View, Tools: View>: View {
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let tools: () -> Tools

    var body: some View {
        WithPerceptionTracking {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    primary().frame(minWidth: 180, maxWidth: .infinity)
                    tools().fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    primary().frame(maxWidth: .infinity)
                    tools().frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

extension View {
    func centeredCatalogPlaybackRow(in width: CGFloat) -> some View {
        frame(width: CatalogDetailLayout.actionsWidth(in: width, wide: true))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    func catalogDetailToolTarget() -> some View {
        frame(width: 44, height: 48).contentShape(Rectangle())
    }
}
#endif
