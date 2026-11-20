import SwiftUI
import Perception
import TVCore

#if os(iOS)
enum CatalogDetailLayout {
    static func heroHeight(in size: CGSize) -> CGFloat {
        if size.width >= 700 {
            return min(size.height * 0.84, max(480, size.width * 0.57))
        }
        return min(580, max(410, size.width * 1.18))
    }

    static func cardWidth(in width: CGFloat) -> CGFloat {
        width >= 700 ? min(280, max(216, (width - 40) / 4.5)) : min(216, max(180, width * 0.55))
    }

    static func actionsWidth(in width: CGFloat, wide: Bool) -> CGFloat {
        wide ? min(480, (width - 40) * 0.48) : max(0, width - 40)
    }
}

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
                Image(decorative: paint.image, scale: 1).resizable().scaledToFill()
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
}

struct CatalogDetailHero<Identity: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let size: CGSize
    @ViewBuilder let identity: () -> Identity
    @ViewBuilder let actions: () -> Actions

    private var wide: Bool { size.width >= 700 && !typeSize.isAccessibilitySize }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: max(96, CatalogDetailLayout.heroHeight(in: size) * (wide ? 0.57 : 0.46)))
                if wide {
                    HStack(alignment: .bottom, spacing: 28) {
                        identity().frame(maxWidth: .infinity, alignment: .leading)
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

struct CatalogDetailToolStrip<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @ViewBuilder let content: () -> Content

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) { content() }
                .font(.system(size: 19, weight: .regular)).foregroundStyle(.white.opacity(0.85))
                .buttonStyle(.plain)
                .background {
                    if opaque { Capsule().fill(Color(white: 0.26)) }
                    else { Capsule().fill(.ultraThinMaterial).overlay { Capsule().fill(.white.opacity(0.06)) } }
                }
                .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75).allowsHitTesting(false) }
                .clipShape(Capsule())
        }
    }
}

struct CatalogDetailActionRow<Primary: View, Tools: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let containerWidth: CGFloat
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let tools: () -> Tools

    var body: some View {
        WithPerceptionTracking {
            let width = CatalogDetailLayout.actionsWidth(in: containerWidth, wide: containerWidth >= 700 && !typeSize.isAccessibilitySize)
            if width >= 324 {
                HStack(spacing: 12) {
                    primary().frame(minWidth: 180, maxWidth: .infinity)
                    tools().fixedSize()
                }
            } else {
                VStack(alignment: .trailing, spacing: 10) { primary(); tools() }
            }
        }
    }
}

extension View {
    func catalogDetailToolTarget() -> some View {
        frame(width: 44, height: 52).contentShape(Rectangle())
    }
}
#endif
