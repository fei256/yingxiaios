import SwiftUI
import Perception
import TVCore

#if os(iOS)
enum LocalHomeSourceKind: String, CaseIterable, Identifiable {
    case sites, python, html
    var id: String { rawValue }
}

/// All supported home destinations share the same selector and saved selection.
struct LocalHomeSourcePanel: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var keyboardVisible = false
    @AppStorage(LocalHTMLHomeStore.key) private var htmlHomeData = Data()
    @State private var kind: LocalHomeSourceKind
    @State private var query = ""
    @State private var websiteShown = false
    @State private var importsFile = false
    @State private var importKind = LocalDocumentSelectionKind.subscriptionFile
    @State private var importing = false
    @State private var status = ""
    let selectedHome: LocalHomeTarget
    let pick: (Site) -> Void
    let home: () -> Void
    let close: () -> Void

    init(initialKind: LocalHomeSourceKind, selectedHome: LocalHomeTarget, pick: @escaping (Site) -> Void,
         home: @escaping () -> Void, close: @escaping () -> Void) {
        _kind = State(initialValue: initialKind)
        self.selectedHome = selectedHome
        self.pick = pick
        self.home = home
        self.close = close
    }

    private var sourceGroup: LocalSourceGroup { kind == .python ? .python : .subscription }
    private var activeSubscription: SubscriptionEntry? { store.managedSubscriptions(in: sourceGroup).first(where: \.enabled) }
    private var htmlHomes: LocalHTMLHomeStore { _ = htmlHomeData; return .load() }
    private var busy: Bool { importing || store.importing || store.restoringBackup }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10),
              count: dynamicType.isAccessibilitySize ? 1 : sizeClass == .regular ? 3 : 2)
    }
    private var candidates: [Site] {
        guard let config = store.subscription else { return [] }
        let visible = Set(store.sourceGroups(includeHidden: false).filter { $0.kind != .hidden }.flatMap(\.sites).map(\.key))
        return store.homeSourceSites(config).filter {
            !$0.isBuiltIn && visible.contains($0.key) && (store.localSourceGroup(for: $0) == .python) == (kind == .python)
        }
    }
    private var matches: [Site] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter { text.isEmpty || $0.name.localizedStandardContains(text) }
    }
    private var htmlMatches: [LocalHTMLHomeSource] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return htmlHomes.sources.filter { text.isEmpty || $0.name.localizedStandardContains(text) }
    }
    private var showsBuiltin: Bool {
        kind == .sites && (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || "默认首页".localizedStandardContains(query))
    }
    private var websiteSite: Site? {
        guard let activeSubscription, let document = store.documents[activeSubscription.address] else { return nil }
        return document.sites.first { $0.raw["catPawOpen"] != nil }
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                titleBar
                if !keyboardVisible {
                    Picker("首页类别", selection: $kind) {
                        Text("站点首页").tag(LocalHomeSourceKind.sites)
                        Text("Python").tag(LocalHomeSourceKind.python)
                        Text("HTML 首页").tag(LocalHomeSourceKind.html)
                    }
                    .pickerStyle(.segmented).disabled(busy)
                    .padding(.horizontal, 18).padding(.bottom, 14)
                    .accessibilityIdentifier("home.source.kind")
                    subscriptions
                }
                search
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("全部 \(kind == .html ? htmlMatches.count : matches.count + (showsBuiltin ? 1 : 0))")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        LazyVGrid(columns: columns, spacing: 10) {
                            if showsBuiltin {
                                choice("默认首页", selected: selectedHome == .builtin, identifier: "home.source.builtin") { chooseHome("builtin") }
                            }
                            if kind == .html {
                                ForEach(htmlMatches) { source in
                                    WithPerceptionTracking {
                                        choice(source.name, selected: selectedHome == .html(source.id), identifier: "home.source.html." + source.id) {
                                            chooseHome(source.id)
                                        }
                                    }
                                }
                            } else {
                                ForEach(matches) { site in
                                    WithPerceptionTracking {
                                        choice(site.name, selected: isSelected(site), identifier: "source." + site.key) { pick(site) }
                                    }
                                }
                            }
                        }
                        if busy { ProgressView(importing ? "正在导入…" : "正在恢复来源…") }
                        else if kind == .html && htmlMatches.isEmpty {
                            Text(htmlHomes.sources.isEmpty ? "添加在线地址或导入 HTML 文件后，可在这里选择首页。" : "没有匹配的首页")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if kind != .html && matches.isEmpty {
                            Text(candidates.isEmpty ? "在配置中添加来源后，可在这里选择首页。" : "没有匹配的站源")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.horizontal, 18).padding(.bottom, 24)
                }
            }
            .environment(\.localSettingsAtmosphere, true)
            .toolbar(.hidden, for: .navigationBar)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardVisible = false }
            .appOnChange(of: kind) { _, _ in query = "" }
            .localDocumentImporter(isPresented: $importsFile, kind: importKind) { result in
                switch result {
                case .success(let selection): importDocuments(selection)
                case .failure(let error): status = error.localizedDescription
                }
            }
            .sheet(isPresented: $websiteShown) {
                WithPerceptionTracking {
                    if let entry = activeSubscription, let document = store.documents[entry.address], let site = websiteSite {
                        ConfigCenterView { await CatPawOpen.configCenter(site: site, origin: document.origin, jarURL: document.spiderURL) }
                    }
                }
            }
        }
    }

    private var titleBar: some View {
        VStack(spacing: 10) {
            Capsule().fill(Color.primary.opacity(0.25)).frame(width: 42, height: 5).accessibilityHidden(true)
            HStack(spacing: 6) {
                Text("选择首页").font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                RouteLink {
                    if kind == .html {
                        SettingsPage(title: "HTML 首页", symbol: "globe") { LocalHTMLHomeSettingsSection() }
                            .toolbar(.visible, for: .navigationBar)
                    } else {
                        LocalSourceSettingsView(kind: sourceGroup).toolbar(.visible, for: .navigationBar)
                    }
                } label: { toolbarIcon("gearshape") }
                .accessibilityLabel(kind == .html ? "HTML 首页设置" : kind == .python ? "Python 设置" : "订阅设置")
                .accessibilityIdentifier("home.source.settings." + (kind == .html ? "html" : kind == .python ? "python" : "subscription"))
                Button {
                    importKind = kind == .html ? .htmlFile : kind == .python ? .pythonFiles : .subscriptionFile
                    importsFile = true
                } label: { toolbarIcon("arrow.down.to.line") }
                .disabled(busy).accessibilityLabel("导入首页或来源文件").accessibilityIdentifier("home.source.import")
                Button(action: close) { toolbarIcon("xmark") }
                    .accessibilityLabel("关闭").accessibilityIdentifier("home.source.close")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height > 60 && value.translation.height > abs(value.translation.width) { close() }
        })
    }

    @ViewBuilder private var subscriptions: some View {
        if kind != .html {
            HStack {
                Menu {
                    WithPerceptionTracking {
                        ForEach(store.managedSubscriptions(in: sourceGroup)) { entry in
                            Button { Task { await store.setSubscription(entry, enabled: true) } } label: {
                                if entry.enabled { Label(entry.title, systemImage: "checkmark") }
                                else { Text(entry.title) }
                            }
                        }
                        if store.managedSubscriptions(in: sourceGroup).isEmpty { Text("尚未导入订阅") }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(activeSubscription?.title ?? "选择订阅").lineLimit(2)
                        Image(systemName: "chevron.down").font(.caption)
                    }.frame(minHeight: 44)
                }.disabled(busy).accessibilityIdentifier("home.source.subscription")
                Spacer(minLength: 4)
                if kind == .sites && websiteSite != nil {
                    Button { websiteShown = true } label: { toolbarIcon("globe") }
                        .accessibilityLabel("配置中心").accessibilityIdentifier("home.source.website")
                }
            }
            .font(.subheadline).buttonStyle(.plain)
            .padding(.horizontal, 18).padding(.bottom, 8)
        }
    }

    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(kind == .html ? "搜索首页" : "搜索站源", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .accessibilityIdentifier(kind == .html ? "home.source.html.search" : "source.panel.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 48)
        .localSettingsSurface(cornerRadius: 14)
        .padding(.horizontal, 18).padding(.bottom, 16)
    }

    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 20))
            .frame(width: 44, height: 44)
            .background(Color.primary.opacity(0.055), in: Circle()).contentShape(Circle())
    }

    private func choice(_ title: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { LocalHomeChoiceLabel(title: title, selected: selected) }
            .buttonStyle(.plain).disabled(busy)
            .accessibilityIdentifier(identifier).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isSelected(_ site: Site) -> Bool {
        guard let config = store.subscription else { return false }
        return selectedHome == .source(LocalHomeSourceSelection(origin: site.origin(or: config.origin).absoluteString,
            sourceKey: site.sourceKey, python: store.localSourceGroup(for: site) == .python))
    }

    private func chooseHome(_ id: String) {
        var next = htmlHomes
        next.select(id)
        do { try next.save(); home() }
        catch { status = error.localizedDescription }
    }

    private func importDocuments(_ selection: LocalDocumentSelection) {
        guard !busy else { selection.release(); return }
        importing = true
        let group: LocalSourceGroup = selection.kind == .pythonFiles ? .python : .subscription
        Task {
            defer { importing = false }
            let report = await selection.importDocuments(progress: { index, total, _ in
                status = "正在导入 \(index) / \(total)"
            }) { index, url in
                if selection.kind == .htmlFile {
                    let data = try await selection.readData(at: index, maxBytes: 1024 * 1024)
                    var next = LocalHTMLHomeStore.load()
                    try next.importHTML(name: "", originalFilename: url.lastPathComponent, data: data)
                    try next.save()
                    return "已保存首页"
                }
                guard !store.importing else {
                    throw NSError(domain: "LocalHomeImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "其他来源正在导入，请稍后重试"])
                }
                await store.importLocalSources([url], group: group, name: "", importingCopy: true)
                if let error = store.importError { throw NSError(domain: "LocalHomeImport", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
                return store.notice ?? "已保存来源"
            }
            status = report.message
        }
    }
}
#endif
