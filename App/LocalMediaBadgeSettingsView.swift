#if os(iOS)
import SwiftUI

struct LocalMediaBadgeSettingsView: View {
    @Environment(\.isLocalPageActive) private var pageActive
    @AppStorage(LocalMediaBadgeStore.enabledKey) private var enabled = true
    @State private var store = LocalMediaBadgeStore.load()
    @State private var address = ""
    @State private var busy = false
    @State private var message = ""
    @State private var preview: LocalMediaBadgeSource?
    @State private var importer = LocalMediaBadgeImporter()
    var body: some View {
        SettingsPage(title: "媒体徽章", symbol: "seal.fill") {
            SettingsGroup { Toggle("开启媒体徽章", isOn: $enabled) }
            SettingsGroup(title: "添加徽章方案") {
                TextField("HTTP / HTTPS 徽章地址", text: $address).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(busy ? "正在导入…" : "添加地址", action: add).disabled(busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            SettingsGroup(title: "徽章方案", footer: "每次应用一个方案；删除当前方案后恢复内置徽章。") {
                ForEach(store.sources) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.name).font(.headline)
                        Text("\(source.rules?.rules.count ?? 0) 枚徽章").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array((source.rules?.rules.map(\.row) ?? []).prefix(8))) { badge in
                                    LocalMediaBadgeImage(badge: badge, builtin: source.isBuiltin)
                                }
                            }.frame(minHeight: 26)
                        }
                        if !source.address.isEmpty { Text(source.address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        HStack {
                            Button("预览") { preview = source }.buttonStyle(.bordered).frame(minHeight: 44)
                            Spacer(minLength: 0)
                            Button(store.activeID == source.id ? "已应用" : "应用") { change { $0.apply(source.id) } }
                                .buttonStyle(.bordered).disabled(store.activeID == source.id)
                            if !source.isBuiltin {
                                Button(role: .destructive) { change { $0.remove(source.id) } } label: {
                                    Image(systemName: "trash").frame(width: 44, height: 44)
                                }.buttonStyle(.plain).accessibilityLabel("删除 " + source.name)
                            }
                        }
                    }.padding(.vertical, 4).accessibilityElement(children: .contain).accessibilityIdentifier("settings.badges." + source.name)
                }
            }
        }
        .localGlassDialog(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }), title: preview?.name ?? "徽章预览") {
            if let source = preview {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
                        ForEach(source.rules?.rules.map(\.row) ?? []) { badge in
                            VStack(spacing: 7) {
                                LocalMediaBadgeImage(badge: badge, builtin: source.isBuiltin).frame(height: 24)
                                Text(badge.name).font(.caption).lineLimit(2)
                            }.frame(minHeight: 62)
                        }
                    }.padding()
                }.localGlassBackdrop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalMediaBadgeStore.changed)) { _ in
            store = LocalMediaBadgeStore.load()
            if let preview { self.preview = store.sources.first { $0.id == preview.id } }
        }
        .onDisappear { cancelImport() }
        .appOnChange(of: pageActive) { _, active in if !active { cancelImport() } }
    }
    private func change(_ mutate: (inout LocalMediaBadgeStore) -> Void) {
        var next = LocalMediaBadgeStore.load(); mutate(&next)
        do { try next.save(); store = next; message = "" } catch { message = error.localizedDescription }
    }
    private func add() {
        guard !busy else { return }
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let started = try importer.start(address: value) { result in
                busy = false
                switch result {
                case .success(let next): store = next; address = ""; message = "已添加徽章方案，可预览后应用。"
                case .failure(let error): message = error.localizedDescription
                }
            }
            if started { busy = true; message = "" }
        } catch { message = error.localizedDescription }
    }
    private func cancelImport() {
        importer.cancel()
        if busy { busy = false; message = "导入已取消，可重新添加地址。" }
    }
}

struct LocalMediaBadgeImage: View {
    let badge: PlayerBadgeRules.Row
    let builtin: Bool
    var body: some View {
        if builtin, let image = UIImage(named: "MediaBadge-" + badge.id) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: min(110, max(1, image.size.width / max(1, image.size.height) * 22)), height: 22)
                .accessibilityLabel(badge.name)
        } else {
            AsyncImage(url: URL(string: badge.imageURL)) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else { Text(badge.name).font(.caption2).padding(.horizontal, 5).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4)) }
            }.frame(maxWidth: 110, minHeight: 22, maxHeight: 22).accessibilityLabel(badge.name)
        }
    }
}
#endif
