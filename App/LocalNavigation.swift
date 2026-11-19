import SwiftUI
import Perception
import TVCore

#if os(iOS)
import UIKit
private struct LocalDockKey: EnvironmentKey { static let defaultValue = false }
private struct LocalDockInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct LocalDockTopKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct LocalHTMLDockClearanceKey: EnvironmentKey { static let defaultValue = LocalDockLayout.inset(showsMusic: false) }
private struct LocalDockVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct LocalHTMLDockHiddenKey: EnvironmentKey { static let defaultValue = Binding.constant(false) }
private struct LocalDockScrollEnabledKey: EnvironmentKey { static let defaultValue = false }
private struct LocalDockActivityKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable (UUID, Bool) -> Void)? = nil }
private struct LocalPageActiveKey: EnvironmentKey { static let defaultValue = true }
private struct LocalHomeSourcePanelKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable () -> Void)? = nil }
extension EnvironmentValues {
    var localDockScrollEnabled: Bool {
        get { self[LocalDockScrollEnabledKey.self] }
        set { self[LocalDockScrollEnabledKey.self] = newValue }
    }
    var localDockActivity: (@MainActor @Sendable (UUID, Bool) -> Void)? {
        get { self[LocalDockActivityKey.self] }
        set { self[LocalDockActivityKey.self] = newValue }
    }
    var localDockVisible: Bool {
        get { self[LocalDockVisibleKey.self] }
        set { self[LocalDockVisibleKey.self] = newValue }
    }
    var localHTMLDockHidden: Binding<Bool> {
        get { self[LocalHTMLDockHiddenKey.self] }
        set { self[LocalHTMLDockHiddenKey.self] = newValue }
    }
    var openLocalHomeSources: (@MainActor @Sendable () -> Void)? {
        get { self[LocalHomeSourcePanelKey.self] }
        set { self[LocalHomeSourcePanelKey.self] = newValue }
    }
    var localDockInset: CGFloat {
        get { self[LocalDockInsetKey.self] }
        set { self[LocalDockInsetKey.self] = newValue }
    }
    /// The reserved dock's top in global coordinates; pushed and full-bleed
    /// pages can have different safe-area origins but share this boundary.
    var localDockTop: CGFloat? {
        get { self[LocalDockTopKey.self] }
        set { self[LocalDockTopKey.self] = newValue }
    }
    /// Full dock clearance, including the music strip, even while the dock is hidden.
    var localHTMLDockClearance: CGFloat {
        get { self[LocalHTMLDockClearanceKey.self] }
        set { self[LocalHTMLDockClearanceKey.self] = newValue }
    }
    var isLocalPageActive: Bool {
        get { self[LocalPageActiveKey.self] }
        set { self[LocalPageActiveKey.self] = newValue }
    }
    var usesLocalDock: Bool {
        get { self[LocalDockKey.self] }
        set { self[LocalDockKey.self] = newValue }
    }
}

/// A stable stack per visited page. Switching tabs never destroys an in-flight detail or the music queue.
struct LocalAppNavigation: View {
    @Environment(Store.self) private var store
    @State private var visited: Set<AppSection> = [.home]
    @State private var sourcePanel: LocalHomeSourceKind?
    @State private var sourcePanelBlocksInput = false
    @State private var pickedSites: [AppSection: Site] = [:]
    @State private var metadataRevision = TMDBServiceSettings.identity
    @State private var keyboardVisible = false
    @State private var dockHiddenByScroll = false
    @State private var activeScrollObservers: Set<UUID> = []
    @State private var htmlDockHidden = false
    @State private var restoredDestination = false
    @State private var preparedHomeSource = false
    @State private var homeRevision = 0
    @State private var homeResetID: UUID?
    @State private var selectedHome = LocalHomeTarget.load()
    @State private var homeTaps = LocalHomeTapState()
    @State private var pendingHomeNavigation = false
    @State private var homeNotice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .caption2) private var dockLabelSize: CGFloat = 11
    @AppStorage(LocalHTMLHomeStore.key) private var htmlHomeData = Data()
    @AppStorage(LocalHomeTarget.storageKey) private var homeSelectionData = Data()
    let page: (AppSection) -> AnyView
    private let entries: [AppSection] = [.home, .history, .music, .settings, .search, .push]
    private var current: AppSection {
        switch store.section {
        case .discover, .live: .home
        case .more: .settings
        default: store.section
        }
    }
    private var htmlHomeSelected: Bool {
        _ = htmlHomeData
        return current == .home && LocalHTMLHomeStore.load().active != nil
    }
    private var dockVisible: Bool { !keyboardVisible && !dockHiddenByScroll && !(htmlHomeSelected && htmlDockHidden) }

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { viewport in
                WithPerceptionTracking {
                    ZStack {
                        ForEach(Array(visited).sorted { $0.rawValue < $1.rawValue }) { section in
                            WithPerceptionTracking {
                                RouteStack(reset: section == .home ? homeResetID : nil) {
                                    WithPerceptionTracking {
                                        if section == .sites || section == .python {
                                            sourcePage(section)
                                        } else if section == .home {
                                            if preparedHomeSource { LocalHTMLHomeContent { page(section) } }
                                            else { Color.clear }
                                        } else { page(section) }
                                    }
                                }
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .environment(\.isLocalPageActive, current == section && !sourcePanelBlocksInput)
                                .environment(\.localDockInset, keyboardVisible ? 0 : dockInset)
                                .id(stackIdentity(section))
                                .opacity(current == section ? 1 : 0)
                                .disabled(current != section || sourcePanelBlocksInput)
                                .allowsHitTesting(current == section && !sourcePanelBlocksInput)
                                .accessibilityHidden(current != section || sourcePanelBlocksInput)
                                .zIndex(current == section ? 1 : 0)
                            }
                        }
                    }
                    .environment(\.localDockTop, keyboardVisible ? nil : viewport.frame(in: .global).maxY - dockInset)
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .overlay(alignment: .bottom) {
                        WithPerceptionTracking {
                            if dockVisible {
                                let metrics = LocalDockLayout.metrics(availableWidth: viewport.size.width - 2 * LocalDockLayout.horizontalPadding)
                                VStack(spacing: LocalDockLayout.musicSpacing) {
                                    if store.music.showsStrip(videoPlaying: store.playing != nil) {
                                        MusicMiniPlayer().frame(width: metrics.width, height: LocalDockLayout.musicHeight)
                                            .localGlassSurface(cornerRadius: 28)
                                    }
                                    dock(availableWidth: viewport.size.width - 2 * LocalDockLayout.horizontalPadding)
                                }
                                .padding(.horizontal, LocalDockLayout.horizontalPadding)
                                .padding(.top, LocalDockLayout.topPadding).padding(.bottom, LocalDockLayout.bottomPadding)
                                .localDockHitRegions(frames: LocalDockLayout.touchFrames(containerWidth: viewport.size.width,
                                    showsMusic: store.music.showsStrip(videoPlaying: store.playing != nil), controlHeight: dockControlHeight))
                                .disabled(sourcePanelBlocksInput)
                                .allowsHitTesting(!sourcePanelBlocksInput)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                    .overlay(alignment: .top) {
                        if let homeNotice {
                            Text(homeNotice).font(.footnote).padding(12)
                                .background(.regularMaterial, in: Capsule()).padding(.top, 12)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .environment(\.usesLocalDock, true)
            .environment(\.localDockVisible, dockVisible)
            .environment(\.localHTMLDockClearance, dockInset)
            .environment(\.localHTMLDockHidden, $htmlDockHidden)
            .environment(\.localDockScrollEnabled, !keyboardVisible && !sourcePanelBlocksInput)
            .environment(\.localDockActivity, { id, active in scrolled(id: id, active: active) })
            .environment(\.openLocalHomeSources, { openHomeSources() })
            .onAppear { prepareHomeDestination(); visited.insert(current); revealDock() }
            .task(id: sourceRevision) { prepareHomeDestination(); synchronizeSources() }
            .appOnChange(of: store.section) { _, section in
                if section != .home && section != .sites && section != .python {
                    homeTaps.reset(); pendingHomeNavigation = false
                }
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                visited.insert(current)
                revealDock()
            }
            .appOnChange(of: scenePhase) { _, phase in
                if phase != .active { homeTaps.reset(); pendingHomeNavigation = false }
            }
            .appOnChange(of: homeSelectionData) { _, _ in
                let target = LocalHomeTarget.load()
                if target != selectedHome {
                    selectedHome = target; pendingHomeNavigation = false; homeTaps.reset()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            // Keep the dock out of the keyboard's shrinking safe area until dismissal finishes.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardVisible = false }
            .onReceive(NotificationCenter.default.publisher(for: TMDBServiceSettings.changed)) { _ in
                metadataRevision = TMDBServiceSettings.identity
            }
            .localGlassDialog(isPresented: Binding(get: { sourcePanel != nil }, set: { if !$0 { sourcePanel = nil } }), title: "",
                              maxWidth: LocalSettingsAppearance.maximumWidth, layout: .homePicker,
                              onDismiss: { sourcePanelBlocksInput = false; homeTaps.reset() }) {
                RouteStack {
                    WithPerceptionTracking {
                        LocalHomeSourcePanel(initialKind: sourcePanel ?? .sites, selectedHome: homeTarget,
                                             pick: select, home: selectHome, close: { sourcePanel = nil })
                    }
                }
                .environment(store)
                .toolbarBackground(.hidden, for: .navigationBar)
            }
            .onDisappear { revealDock() }
            .task(id: homeNotice) {
                guard homeNotice != nil else { return }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                homeNotice = nil
            }
            .fullScreenCover(isPresented: Binding(get: { store.music.presentsPlayer }, set: { store.music.presentsPlayer = $0 })) {
                MusicNowPlayingScreen().environment(store)
            }
        }
    }

    private func stackIdentity(_ section: AppSection) -> String {
        guard section == .sites || section == .python, let site = pickedSites[section] else {
            return section == .home || section == .discover ? section.rawValue + "|" + metadataRevision + "|\(homeRevision)" : section.rawValue
        }
        // Only the live stack uses this process-local hash. Persisted identity stays origin + original key.
        return section.rawValue + "|" + site.key + "|\(site.hashValue)"
    }

    @ViewBuilder private func sourcePage(_ section: AppSection) -> some View {
        if let site = pickedSites[section], let config = store.subscription {
            SiteView(site: site, origin: config.origin, jarURL: config.spiderURL)
                .id(site.key + "|" + site.origin(or: config.origin).absoluteString)
        } else {
            VStack(spacing: 18) {
                Image(systemName: section.icon).font(.system(size: 44)).foregroundStyle(.secondary)
                Text(section == .python ? "选择 python 来源" : "选择站点").font(.title2)
                Button("选择来源") { presentSources(section == .python ? .python : .sites) }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).screenBackdrop()
        }
    }

    private var sourceRevision: String {
        let readiness = store.subscriptions.map { entry in
            "\(entry.address)|\(entry.enabled)|\(store.documents[entry.address] != nil)|\(store.subscriptionErrors[entry.address] != nil)"
        }.joined(separator: "\n")
        guard let config = store.subscription else { return "empty|\(store.importing)|\(store.restoringBackup)|" + readiness }
        return config.importedAt.description + "|\(store.importing)|\(store.restoringBackup)|" + readiness + "|" + config.sites.map {
            $0.key + "|" + $0.origin(or: config.origin).absoluteString
        }.joined(separator: "\n")
    }

    private func prepareHomeDestination() {
        guard !preparedHomeSource else { return }
        var home = LocalHTMLHomeStore.load()
        let previous = home
        let preference = LocalHomeDestination(rawValue: UserDefaults.standard.string(forKey: LocalHomeDestination.key) ?? "") ?? .home
        home.restoreStartup(preference)
        if home != previous {
            do { try home.save() }
            catch { Diagnostics.shared.record(.warning, "home", "startup home could not be saved") }
        }
        preparedHomeSource = true
    }

    private func selection(for site: Site, origin: URL) -> LocalHomeSourceSelection {
        LocalHomeSourceSelection(origin: site.origin(or: origin).absoluteString, sourceKey: site.sourceKey, python: store.localSourceGroup(for: site) == .python)
    }

    private func synchronizeSources() {
        guard !store.importing else { return }
        let defaults = UserDefaults.standard
        let sites = store.subscription.map { config in store.orderedSites(config).filter { !$0.isBuiltIn } } ?? []
        if let config = store.subscription {
            for section in [AppSection.sites, .python] {
                let remembered = pickedSites[section].map { selection(for: $0, origin: config.origin) }
                    ?? LocalHomeSourceSelection.saved(python: section == .python, defaults: defaults)
                pickedSites[section] = sites.first { selection(for: $0, origin: config.origin) == remembered }
            }
        } else { pickedSites = [:] }
        if restoredDestination {
            if pendingHomeNavigation && !sourcePanelBlocksInput { returnToSelectedHome() }
            return
        }
        let preference = defaults.string(forKey: "local.home.defaultDestination") ?? "home"
        guard current == .home, preference == "lastSite" || preference == "lastPython",
              LocalHomeSourceSelection.saved(python: preference == "lastPython", defaults: defaults) != nil else {
            restoredDestination = true
            migrateHomeSelection()
            return
        }
        let desired = store.subscription.flatMap { config in
            LocalHomeSourceSelection.destination(preference, available: sites.map { selection(for: $0, origin: config.origin) }, defaults: defaults)
        }
        // Another category can already have a cached document when the target's restore has not begun.
        // Each category has one enabled owner; failed, disabled and deleted entries settle on home.
        let targetGroup: LocalSourceGroup = preference == "lastPython" ? .python : .subscription
        if desired == nil, store.subscriptions.contains(where: { entry in
            entry.enabled && (store.localSourceGroups[entry.address] ?? .subscription) == targetGroup
                && store.documents[entry.address] == nil && store.subscriptionErrors[entry.address] == nil
        }) { return }
        restoredDestination = true
        guard let config = store.subscription, let desired,
              let site = sites.first(where: { selection(for: $0, origin: config.origin) == desired }) else { migrateHomeSelection(); return }
        navigate(to: site)
        migrateHomeSelection()
    }

    private func select(_ site: Site) {
        guard let config = store.subscription,
              rememberHome(.source(selection(for: site, origin: config.origin))) else { return }
        navigate(to: site)
        sourcePanel = nil
    }

    private func navigate(to site: Site) {
        store.cancelResume()
        let section: AppSection = store.localSourceGroup(for: site) == .python ? .python : .sites
        pickedSites[section] = site
        if let config = store.subscription { selection(for: site, origin: config.origin).save() }
        store.section = section
        visited.insert(section)
    }

    private func selectHome() {
        let home = LocalHTMLHomeStore.load()
        let target: LocalHomeTarget = home.active.map { .html($0.id) } ?? .builtin
        let changed = target != selectedHome
        guard rememberHome(target) else { return }
        if changed {
            homeResetID = UUID()
            if target == .builtin { homeRevision += 1 }
        }
        store.cancelResume()
        store.section = .home
        visited.insert(.home)
        sourcePanel = nil
    }

    private func openHomeSources() {
        homeTaps.reset(); pendingHomeNavigation = false; homeNotice = nil
        restoredDestination = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let kind: LocalHomeSourceKind
        switch homeTarget {
        case .source(let source): kind = source.python ? .python : .sites
        case .html: kind = .html
        case .builtin: kind = .sites
        }
        presentSources(kind)
    }

    private func presentSources(_ kind: LocalHomeSourceKind) {
        guard sourcePanel == nil && !sourcePanelBlocksInput else { return }
        homeTaps.reset()
        store.cancelResume()
        // Remain blocked after a selection sets sourcePanel to nil. UIKit's
        // dismissal completion owns re-enabling the underlying retained page.
        sourcePanelBlocksInput = true
        sourcePanel = kind
    }

    private var currentHomeTarget: LocalHomeTarget? {
        if current == .home {
            return LocalHTMLHomeStore.load().active.map { .html($0.id) } ?? .builtin
        }
        if let site = pickedSites[current], let config = store.subscription {
            return .source(selection(for: site, origin: config.origin))
        }
        return nil
    }

    private var homeTarget: LocalHomeTarget {
        if let selectedHome { return selectedHome }
        let preference = LocalHomeDestination(rawValue: UserDefaults.standard.string(forKey: LocalHomeDestination.key) ?? "") ?? .home
        if preference == .lastSite || preference == .lastPython,
           let source = LocalHomeSourceSelection.saved(python: preference == .lastPython) { return .source(source) }
        if preference == .lastHTML, let id = LocalHTMLHomeStore.load().lastHTMLID { return .html(id) }
        return currentHomeTarget ?? .builtin
    }

    @discardableResult private func rememberHome(_ target: LocalHomeTarget) -> Bool {
        do { try target.save(); selectedHome = target; return true }
        catch { homeNotice = "无法保存首页选择，请稍后重试"; return false }
    }

    private func migrateHomeSelection() {
        if selectedHome == nil, let target = currentHomeTarget { rememberHome(target) }
    }

    private func homeTapped() {
        switch homeTaps.tap(at: ProcessInfo.processInfo.systemUptime, blocked: sourcePanelBlocksInput) {
        case .showHome:
            restoredDestination = true
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            returnToSelectedHome()
        case .chooseHome: openHomeSources()
        case .ignored: break
        }
    }

    private func showBuiltinHome() {
        var home = LocalHTMLHomeStore.load()
        if home.activeID != "builtin" {
            home.select("builtin")
            do { try home.save() } catch { homeNotice = "无法切换首页，请稍后重试" }
        }
        store.section = .home
        visited.insert(.home)
    }

    private func returnToSelectedHome() {
        guard !sourcePanelBlocksInput else { return }
        store.cancelResume()
        let target = homeTarget
        let homes = LocalHTMLHomeStore.load()
        let config = store.subscription
        let sites = config.map { store.orderedSites($0).filter { !$0.isBuiltIn } } ?? []
        let sources = config.map { config in sites.map { selection(for: $0, origin: config.origin) } } ?? []
        var loadingGroups: Set<Bool> = []
        for entry in store.subscriptions where entry.enabled {
            if store.importing || (store.documents[entry.address] == nil && store.subscriptionErrors[entry.address] == nil) {
                loadingGroups.insert((store.localSourceGroups[entry.address] ?? .subscription) == .python)
            }
        }
        if store.restoringBackup { loadingGroups = [false, true] }
        switch target.resolve(sources: sources, htmlIDs: Set(homes.sources.map(\.id)), loadingGroups: loadingGroups) {
        case .waiting:
            pendingHomeNavigation = true
            showBuiltinHome()
            homeNotice = "正在恢复所选首页…"
        case .unavailable:
            pendingHomeNavigation = false
            showBuiltinHome()
            homeNotice = "所选首页暂不可用，已返回默认首页"
        case .available:
            pendingHomeNavigation = false
            homeNotice = nil
            switch target {
            case .builtin: showBuiltinHome()
            case .source(let desired):
                if let config, let site = sites.first(where: { selection(for: $0, origin: config.origin) == desired }) { navigate(to: site) }
            case .html(let id):
                guard let source = homes.sources.first(where: { $0.id == id }) else { return }
                var next = homes
                do {
                    if source.isFile { _ = try homes.html(for: source) }
                    next.select(id)
                    if next != homes { try next.save() }
                    store.section = .home; visited.insert(.home)
                } catch {
                    showBuiltinHome(); homeNotice = "首页文件不可用，请重新导入"
                    return
                }
            }
            if selectedHome == nil { rememberHome(target) }
        }
    }

    private var dockInset: CGFloat {
        LocalDockLayout.inset(showsMusic: store.music.showsStrip(videoPlaying: store.playing != nil), controlHeight: dockControlHeight)
    }

    private var dockControlHeight: CGFloat { max(LocalDockLayout.controlHeight, 32 + dockLabelSize * 1.4) }

    private func scrolled(id: UUID, active: Bool) {
        if active { activeScrollObservers.insert(id) } else { activeScrollObservers.remove(id) }
        let hidden = !activeScrollObservers.isEmpty
        guard dockHiddenByScroll != hidden else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: hidden ? 0.16 : 0.18)) { dockHiddenByScroll = hidden }
    }

    private func revealDock() {
        activeScrollObservers.removeAll()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { dockHiddenByScroll = false }
    }

    private func dock(availableWidth: CGFloat) -> some View {
        let metrics = LocalDockLayout.metrics(availableWidth: availableWidth)
        return HStack(spacing: 0) {
            ForEach(entries) { entry in
                WithPerceptionTracking { dockButton(entry, width: metrics.buttonWidth) }
            }
        }
        .padding(metrics.padding)
        .frame(width: metrics.width, height: LocalDockLayout.height(controlHeight: dockControlHeight))
        .localSettingsSurface(cornerRadius: LocalDockLayout.height(controlHeight: dockControlHeight) / 2, navigation: true)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func dockButton(_ entry: AppSection, width: CGFloat) -> some View {
        let selected = current == entry || entry == .home && (current == .sites || current == .python)
        let button = Button {
            if entry == .home { homeTapped() }
            else { selectSection(entry) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: dockSymbol(entry, selected: selected)).font(.system(size: 23, weight: selected ? .semibold : .regular))
                Text(entry.title).font(.system(size: dockLabelSize)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(width: width, height: dockControlHeight)
            .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.55))
            .background(selected ? Color.primary.opacity(0.12) : .clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(dockIdentifier(entry))
        if entry == .home { button.accessibilityAction(named: Text("选择首页"), openHomeSources) }
        else { button }
    }

    private func dockSymbol(_ entry: AppSection, selected: Bool) -> String {
        switch entry {
        case .home: selected ? "house.fill" : "house"
        case .history: selected ? "clock.fill" : "clock"
        case .music: "music.note"
        case .settings: selected ? "gearshape.fill" : "gearshape"
        case .search: "magnifyingglass"
        case .push: selected ? "paperplane.fill" : "paperplane"
        default: entry.icon
        }
    }

    private func dockIdentifier(_ entry: AppSection) -> String {
        switch entry {
        case .home: "local.dock.home"
        case .history: "local.dock.history"
        case .music: "local.dock.music"
        case .settings: "local.dock.settings"
        case .search: "local.search"
        case .push: "local.push"
        default: "local.dock." + entry.id
        }
    }

    private func selectSection(_ section: AppSection) {
        homeTaps.reset(); pendingHomeNavigation = false; homeNotice = nil
        restoredDestination = true
        guard current != section else { return }
        store.cancelResume()
        visited.insert(section)
        store.section = section
    }
}

struct LocalContinueWatching: View {
    @Environment(Store.self) private var store
    @AppStorage("local.home.continueWatching") private var enabled = true
    var body: some View {
        WithPerceptionTracking {
            if enabled, !store.visibleHistory.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Button { store.cancelResume(); store.section = .history } label: {
                        HStack {
                            Text("继续观看").font(.title3.weight(.bold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }.contentShape(Rectangle()).frame(minHeight: 44)
                    }.buttonStyle(.plain).padding(.horizontal, 17)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(store.visibleHistory.prefix(12)) { entry in HistoryCard(entry: entry) }
                        }.padding(.horizontal, 17)
                    }
                }.accessibilityIdentifier("home.continueWatching")
            }
        }
    }
}
#endif
