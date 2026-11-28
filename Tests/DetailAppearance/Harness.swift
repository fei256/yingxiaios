import SwiftUI

@MainActor @main struct DetailChecksApp: App {
    init() {
        FixtureImages.shared.prepare()
        try! TMDBServiceSettings(apiBase: "https://api.fixture/3", apiKey: "fixture-key", imageBase: "https://images.fixture/t/p", enabled: true).save()
    }
    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("episodeHeader") {
                EpisodeHeaderHarness().preferredColorScheme(.dark)
            } else {
                DetailHarness().preferredColorScheme(.dark)
                    .environment(\.dynamicTypeSize, CommandLine.arguments.contains("accessibility") ? .accessibility3 : .large)
            }
        }
    }
}

private struct EpisodeHeaderHarness: View {
    @State private var narrow = false
    @State private var lastAction = "none"
    @State private var episodeCount = 205

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 16) {
                Button { lastAction = "play" } label: {
                    CatalogPlaybackLabel(title: "继续播放", subtitle: "第 201 集 · 片名与文件信息 · 00:17", symbol: "play.fill", loading: false)
                        .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 48)
                        .background { CatalogPlaybackBackground() }
                }
                .accessibilityIdentifier("play").centeredCatalogPlaybackRow(in: geometry.size.width)
                CatalogEpisodeHeader(count: episodeCount, sources: ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("百度无限") { episodeCount = 205 }
                        Button("夸克无限") { episodeCount = 202 }
                    }
                }, detailTools: icons(["rectangle.stack", "arrow.down.circle", "calendar", "ellipsis"]),
                   episodeTools: icons(["list.bullet", "arrow.up.arrow.down"]))
                    .frame(width: narrow ? 280 : nil)
                Button("缩小窗口") { narrow = true }
                Text(lastAction).accessibilityIdentifier("lastAction")
            }
            .padding(20)
        }
    }

    private func icons(_ symbols: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(symbols, id: \.self) { symbol in
                Button { lastAction = symbol } label: {
                    Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityIdentifier(symbol)
            }
        }.buttonStyle(.plain)
    }
}

private struct DetailHarness: View {
    private let backdrop = URL(string: "https://images.fixture/t/p/w1280/background.png")!
    private let logo = URL(string: "https://images.fixture/t/p/w500/logo.png")!
    private let portrait = URL(string: "https://images.fixture/t/p/w185/portrait.png")!
    @State private var paint: DiscoverPaint?
    @State private var imagesReady = false
    @State private var complete = true
    @State private var cachedRanges: [ClosedRange<Double>] = []
    @State private var action = "none"
    @State private var portraitAspect: CGFloat?
    @State private var portraitRequests = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                CatalogDetailBackdrop(paint: paint, width: geometry.size.width, heroHeight: CatalogDetailLayout.heroHeight(in: geometry.size))
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        CatalogDetailHero(size: geometry.size) {
                            VStack(spacing: 10) {
                                LocalCatalogDetailTitle(title: "凡人修仙传", logo: logo, width: geometry.size.width,
                                                        centered: CatalogDetailLayout.usesWideHero(in: geometry.size))
                                    .accessibilityIdentifier("fixture.title")
                                Text("TMDB 8.6 · 2020 · 动画 · 固定测试数据").font(.system(size: 13))
                            }.accessibilityElement(children: .contain).accessibilityIdentifier("fixture.identity")
                        } actions: {
                            CatalogDetailActionRow {
                                Button { action = "play" } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "play.fill").font(.system(size: 23))
                                        VStack(spacing: 3) { Text("继续播放").font(.system(size: 17, weight: .semibold)); Text("第 200 集 · 00:17").font(.system(size: 12)).opacity(0.6) }
                                    }.foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 56).background(.white, in: Capsule())
                                }.buttonStyle(.plain).accessibilityIdentifier("fixture.play")
                            } tools: {
                                CatalogDetailToolStrip {
                                    tool("rectangle.stack", "sources"); tool("link", "link"); tool("calendar", "calendar"); tool("ellipsis", "more")
                                }
                            }.accessibilityElement(children: .contain).accessibilityIdentifier("fixture.actions")
                        }
                        Text("详情组件回归：原生背景、片名、操作胶囊与缓存进度。").font(.footnote).opacity(0.65)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(complete ? "缓存完成" : "部分缓存").font(.headline).accessibilityIdentifier("fixture.cacheStatus")
                            let ranges = PlaybackCacheProgress.bufferedRanges(duration: 1095, position: 55,
                                decodedThrough: 180, cacheComplete: complete, cachedRanges: cachedRanges)
                            ZStack { PlayerTimelineTrack(played: 0.05, buffered: ranges, thickness: 6) }
                                .frame(height: 28).accessibilityElement(children: .ignore)
                                .accessibilityLabel("缓存进度").accessibilityValue(complete ? "complete" : "partial")
                                .accessibilityIdentifier("fixture.cacheTrack")
                            HStack {
                                Button("清理缓存") { complete = false; cachedRanges = [] }.accessibilityIdentifier("fixture.clearCache")
                                Button("分段缓存") { complete = false; cachedRanges = [0...0.6, 0.8...0.85] }
                                    .accessibilityIdentifier("fixture.partialCache")
                                Button("完成缓存") { complete = true }.accessibilityIdentifier("fixture.completeCache")
                            }.buttonStyle(.bordered).frame(minHeight: 44)
                        }.padding(18).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        HStack(spacing: 18) {
                            PosterImage(url: portrait, symbol: "person.fill", aspect: $portraitAspect)
                                .frame(width: 84, height: 84).clipShape(Circle())
                                .accessibilityElement(children: .ignore).accessibilityLabel("测试演员")
                                .accessibilityIdentifier("fixture.avatar")
                            VStack(alignment: .leading, spacing: 8) {
                                Text(portraitAspect == nil ? "avatar waiting" : "avatar ready").accessibilityIdentifier("fixture.avatarStatus")
                                Text("\(portraitRequests)").accessibilityIdentifier("fixture.avatarRequests")
                                Button("修复头像连接") {
                                    FixtureImages.shared.enablePortrait()
                                    var config = TMDBServiceSettings.load(); config.apiKey = "fixture-key-refreshed"
                                    try! config.save()
                                }.accessibilityIdentifier("fixture.retryAvatar")
                            }
                        }
                        Text(imagesReady ? "images ready" : "images loading").font(.caption).accessibilityIdentifier("fixture.imageStatus")
                        Text(action).font(.caption).accessibilityIdentifier("fixture.action")
                    }.padding(.horizontal, 20).padding(.bottom, 40)
                }
            }.foregroundStyle(.white).ignoresSafeArea(edges: .top)
        }
        .task {
            paint = await DiscoverPainter.shared.paint(backdrop, style: .cinematic)
            let wordmark = await TMDBArtwork.load(logo, maxPixels: 1000)
            portraitRequests = FixtureImages.shared.portraitRequestCount
            imagesReady = paint != nil && wordmark != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: FixtureImages.portraitRequested).receive(on: DispatchQueue.main)) { _ in
            portraitRequests = FixtureImages.shared.portraitRequestCount
        }
    }
    private func tool(_ symbol: String, _ name: String) -> some View {
        Button { action = name } label: { Image(systemName: symbol).catalogDetailToolTarget() }
            .accessibilityIdentifier("fixture." + name)
    }
}
