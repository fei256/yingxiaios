import SwiftUI
import TVCore

struct LocalCacheSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var pageActive
    #endif
    @AppStorage("local.videoCache.enabled") private var enabled = true
    @AppStorage("local.videoCache.sizeGB") private var size = 1
    @AppStorage("local.playback.prefetchNext") private var prefetch = true
    @State private var cachedBytes = 0
    @State private var reusedBytes = 0
    @State private var cacheStatus: String?
    @State private var clearing = false
    private var refreshActive: Bool {
        #if os(iOS)
        pageActive && scenePhase == .active
        #else
        scenePhase == .active
        #endif
    }
    var body: some View {
        SettingsPage(title: "视频缓存", symbol: "internaldrive") {
            SettingsGroup(title: "视频缓存", footer: "播放时会提前缓存视频。切换或退出播放后会释放缓存，已下载的视频可继续离线观看。") {
                Toggle("开启视频缓存", isOn: $enabled)
                Picker("缓存容量", selection: $size) { ForEach(1...4, id: \.self) { Text("\($0) GB").tag($0) } }.disabled(!enabled)
                Toggle("预加载下一集", isOn: $prefetch)
            }
            SettingsGroup(title: "缓存使用情况") {
                SettingsRow(symbol: "internaldrive", tint: Brand.cyan, title: "已缓存 \(ByteCountFormatter.string(fromByteCount: Int64(cachedBytes), countStyle: .file))")
                SettingsRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: "已复用 \(ByteCountFormatter.string(fromByteCount: Int64(reusedBytes), countStyle: .file))")
                if let cacheStatus { Text(cacheStatus).font(.footnote).foregroundStyle(.secondary) }
                SettingsActionRow(title: clearing ? "清理中…" : "清理视频缓存", destructive: true) {
                    clearing = true
                    Task {
                        do { try await MobileMediaServices.clearVideoCache(); await refreshUsage() }
                        catch { cacheStatus = "暂时无法连接缓存服务，下次播放时会重试。" }
                        clearing = false
                    }
                }.disabled(clearing)
            }
            SettingsGroup {
                SettingsLinkRow(symbol: "photo.stack", title: "图片、剧集和弹幕缓存") { CacheSettingsView() }
                SettingsLinkRow(symbol: "arrow.down.circle", title: "已下载视频") { DownloadsView() }
            }
        }
        .task(id: "\(enabled):\(size):\(refreshActive)") {
            guard refreshActive else { return }
            do {
                try await MobileMediaServices.configureVideoCache(enabled: enabled, sizeGB: size)
                guard !Task.isCancelled else { return }
                cacheStatus = nil
            } catch {
                guard !Task.isCancelled else { return }
                cacheStatus = "暂时无法连接缓存服务，下次播放时会重试。"
            }
            while refreshActive && !Task.isCancelled {
                await refreshUsage()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    @MainActor private func refreshUsage() async {
        guard let value = try? await MobileMediaServices.videoCacheSummary(), !Task.isCancelled else { return }
        cachedBytes = value.bytes; reusedBytes = value.hits
    }
}

struct LocalAdSettingsView: View {
    @AppStorage("local.hlsAdClean") private var enabled = true
    var body: some View {
        SettingsPage(title: "去广告", symbol: "shield.lefthalf.filled") {
            SettingsGroup(footer: "播放 M3U8 视频时会过滤可识别的广告片段。如果播放异常，可关闭此项后重新打开视频。") {
                Toggle("M3U8 去广告", isOn: $enabled)
            }
        }
    }
}

#if os(iOS)
struct LocalPlayerSettingsView: View {
    @AppStorage(PlaybackKernel.preferenceKey) private var kernel = PlaybackKernel.ksPlayer.rawValue
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    var body: some View {
        SettingsPage(title: "播放器", symbol: "play.rectangle") {
            SettingsGroup(title: "默认播放内核", footer: "从下次播放起生效。Aether 无法播放的片源会自动使用 KSPlayer。") {
                Picker("播放内核", selection: $kernel) {
                    ForEach(PlaybackKernel.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
            }
            SettingsGroup(title: "播放信息") {
                Toggle("显示视频技术信息", isOn: $showsPlaybackInfo)
            }
        }
    }
}
#endif
