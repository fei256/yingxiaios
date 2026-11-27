import SwiftUI
import Perception
import TVCore

#if os(iOS)
struct LocalSettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(LocalAppearance.key) private var appearance = LocalAppearance.system
    @AppStorage("danmakuEnabled") private var danmaku = true
    @AppStorage(LocalMediaBadgeStore.enabledKey) private var badges = true
    @AppStorage("local.hlsAdClean") private var adClean = true
    @AppStorage("local.videoCache.enabled") private var cache = true
    @AppStorage("local.videoCache.sizeGB") private var cacheSize = 1
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(alignment: .leading, spacing: LocalSettingsAppearance.groupSpacing) {
                    LocalSettingsMenuSection(title: "内容来源与首页") {
                        LocalSettingsMenuRow(symbol: "list.bullet.rectangle", title: "订阅", detail: "\(store.managedSubscriptions(in: .subscription).count) 个订阅") { LocalSourceSettingsView(kind: .subscription) }
                        LocalSettingsMenuRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Python", detail: "\(store.managedSubscriptions(in: .python).count) 个来源", identifier: "python") { LocalSourceSettingsView(kind: .python) }
                        LocalSettingsMenuRow(symbol: "house", title: "首页设置", detail: "启动时显示的页面", identifier: "首页", last: true) { LocalHomeSettingsView() }
                    }
                    LocalSettingsMenuSection(title: "播放与显示") {
                        LocalSettingsMenuRow(symbol: "play.rectangle", title: "播放器", detail: "播放信息") { LocalPlayerSettingsView() }
                        LocalSettingsMenuRow(symbol: "text.bubble", title: "弹幕", detail: danmaku ? "已开启" : "已关闭") { LocalDanmakuSettingsView() }
                        LocalSettingsMenuRow(symbol: "tag", title: "媒体徽章", detail: badges ? "已开启" : "已关闭") { LocalMediaBadgeSettingsView() }
                        LocalSettingsMenuRow(symbol: "paintpalette", title: "界面显示", detail: appearance.title) { LocalAppearanceSettingsView() }
                        LocalSettingsMenuRow(symbol: "film.stack", title: "TMDB", detail: "海报与剧集资料") { TMDBServiceSettingsView() }
                        LocalSettingsMenuRow(symbol: "shield.lefthalf.filled", title: "去广告", detail: adClean ? "已开启" : "已关闭", last: true) { LocalAdSettingsView() }
                    }
                    LocalSettingsMenuSection(title: "字幕") {
                        LocalSettingsMenuRow(symbol: "captions.bubble", title: "在线字幕", detail: "字幕服务与语言") { LocalOnlineSubtitleSettingsView() }
                        LocalSettingsMenuRow(symbol: "waveform", title: "AI 字幕", detail: "离线语音字幕", identifier: "AI字幕", last: true) { LocalAISubtitleSettingsView() }
                    }
                    LocalSettingsMenuSection(title: "数据与维护") {
                        LocalSettingsMenuRow(symbol: "heart", title: "收藏", detail: "收藏内容") { FavoritesView() }
                        LocalSettingsMenuRow(symbol: "internaldrive", title: "视频缓存", detail: cache ? "\(cacheSize) GB" : "已关闭") { LocalCacheSettingsView() }
                        LocalSettingsMenuRow(symbol: "archivebox", title: "备份迁移", detail: "导出与恢复") { LocalBackupSettingsView() }
                        LocalSettingsMenuRow(symbol: "doc.plaintext", title: "诊断", detail: "查看诊断日志") { DiagnosticsView() }
                        LocalSettingsMenuRow(symbol: "info.circle", title: "关于", detail: "版本与开源许可", last: true) { LocalAboutView() }
                    }
                }
                .frame(maxWidth: LocalSettingsAppearance.maximumWidth)
                .padding(18).frame(maxWidth: .infinity)
            }
            .localSettingsCanvas().navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

private struct LocalSettingsMenuSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).padding(.leading, LocalSettingsAppearance.rowInset)
            VStack(spacing: 0) { content }
                .localSettingsSurface()
                .clipShape(RoundedRectangle(cornerRadius: LocalSettingsAppearance.cornerRadius, style: .continuous))
        }
    }
}

private struct LocalSettingsMenuRow<Destination: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.displayScale) private var scale
    let symbol: String
    let title: String
    var detail: String = ""
    var identifier: String? = nil
    var last = false
    @ViewBuilder var destination: @MainActor @Sendable () -> Destination
    var body: some View {
        RouteLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 24, weight: .regular))
                    .frame(width: LocalSettingsAppearance.iconWidth)
                    .accessibilityHidden(true)
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.body)
                        if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                } else {
                    Text(title).font(.body).layoutPriority(1)
                    Spacer(minLength: 8)
                    if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, LocalSettingsAppearance.rowInset).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: LocalSettingsAppearance.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !last {
                    Rectangle().fill(Color.primary.opacity(0.075)).frame(height: 1 / max(1, scale))
                        .padding(.leading, LocalSettingsAppearance.rowInset + LocalSettingsAppearance.iconWidth + 12)
                        .allowsHitTesting(false)
                }
            }
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityIdentifier("settings." + (identifier ?? title))
    }
}

struct LocalHomeSettingsView: View {
    @AppStorage(LocalHomeDestination.key) private var destination = LocalHomeDestination.home
    @AppStorage("local.home.continueWatching") private var recent = true
    var body: some View {
        SettingsPage(title: "首页", symbol: "house.fill") {
            LocalAppearanceSettingsSection()
            SettingsGroup(title: "首页") {
                Picker("默认打开", selection: $destination) {
                    ForEach(LocalHomeDestination.allCases) { Text($0.title).tag($0) }
                }
                Toggle("继续观看", isOn: $recent)
            }
            LocalHTMLHomeSettingsSection()
        }
    }
}

struct LocalAboutView: View {
    @Environment(Updates.self) private var updates
    var body: some View {
        WithPerceptionTracking {
            SettingsPage(title: "关于映匣", symbol: "info.circle") {
                SettingsGroup {
                    LabeledContent("版本", value: updates.current)
                    LabeledContent("构建号", value: String(updates.build))
                }
                SettingsGroup {
                    SettingsLinkRow(symbol: "doc.plaintext", title: "开源许可") { LicensesView() }
                    SettingsLinkRow(symbol: "stethoscope", title: "诊断") { DiagnosticsView() }
                    SettingsLinkRow(symbol: "hand.raised", title: "数据与隐私") { LocalDataSettingsView() }
                }
            }
        }
    }
}

private struct LocalDataSettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(CloudSync.enabledKey) private var sync = true
    @AppStorage(CloudSync.availabilityKey) private var available = false
    @AppStorage(CloudSync.lastIncomingKey) private var lastIncoming = 0.0
    var body: some View {
        SettingsPage(title: "数据与隐私", symbol: "hand.raised") {
            SettingsGroup {
                Toggle("iCloud 同步", isOn: $sync)
                    .appOnChange(of: sync) { _, enabled in store.cloudSync?.setEnabled(enabled) }
                if sync {
                    Text(available ? "已向 iCloud 请求同步。" : "iCloud 同步暂不可用。请检查设备是否已登录 iCloud，以及映匣是否有同步权限。")
                    if lastIncoming > 0 { Text("上次收到更新：" + Date(timeIntervalSince1970: lastIncoming).formatted()) }
                    else { Text("尚未收到云端更新。") }
                }
                Text("同步订阅、收藏与观看记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
