import SwiftUI

@MainActor final class SearchInputState: ObservableObject {
    @Published var text = ""
    @Published var focused = false
    @Published var request: GlobalSearchFocusRequest?
    @Published var revision = 0
}

struct SearchInputHarness: View {
    @ObservedObject var state: SearchInputState
    var body: some View {
        GlobalSearchSurface {
            if state.text.isEmpty { GeometryReader { _ in Color.black } }
            else { ScrollView { Text(state.text).frame(maxWidth: .infinity) } }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                GlobalSearchInput(text: $state.text, focused: $state.focused, focusRequest: state.request) {
                    state.request = GlobalSearchFocusRequest(focused: false)
                }.frame(height: 44)
                Button { state.text = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .opacity(state.text.isEmpty ? 0 : 1)
            }.padding(12).background(Color.gray)
        }
        .overlay(alignment: .bottom) { Text("\(state.revision)").accessibilityIdentifier("input.revision") }
    }
}

private struct ControlHarness: View {
    @State private var last = "none"
    @State private var events = 0
    @State private var controlFrames: [CGRect] = []
    var body: some View {
        ZStack {
            Color.black.allowsHitTesting(false)
            PictureGestures(tap: { record($0 == .double ? "playback" : "picture") }, hold: { _ in record("hold") }, swipe: { _ in record("swipe") }, excludedHitRegions: controlFrames) { _ in record("pinch") }
                .ignoresSafeArea()
                .allowsHitTesting(!ProcessInfo.processInfo.arguments.contains("no-picture"))
            VStack(spacing: 30) {
                Text("\(last):\(events)").accessibilityIdentifier("control.last")
                controls("top")
                HStack(spacing: 6) {
                    NativeReferenceButton { record("native.reference") }
                        .frame(width: 48, height: 48).background(Color.gray)
                    Button { record("reference") } label: {
                        Text("R").frame(width: 48, height: 48).background(Color.gray).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("reference")
                    Button { record("plain") } label: {
                        Image(systemName: "play.fill").playerControlTarget()
                    }.buttonStyle(.plain).accessibilityIdentifier("plain")
                    Button { record("styled.rectangle") } label: {
                        Color.gray.frame(width: 48, height: 48).contentShape(Rectangle())
                    }.buttonStyle(PlayerToolbarButtonStyle()).accessibilityIdentifier("styled.rectangle")
                }.playerControlHitRegion()
                Spacer()
                controls("bottom")
                HStack(spacing: 0) {
                    ForEach(0..<6) { index in
                        Button { record("dock.\(index)") } label: {
                            VStack { Image(systemName: "house"); Text("\(index)") }
                                .frame(width: 88, height: 56).background(Color.gray.opacity(0.4))
                                .localDockControlTarget(width: 88, height: 64)
                        }.buttonStyle(.plain).accessibilityIdentifier("dock.\(index)")
                    }
                }.padding(.horizontal, 4).localSettingsSurface(cornerRadius: 32, navigation: true).localDockTouchSurface()
            }.padding(24)
        }.foregroundStyle(.white)
            .onPreferenceChange(PlayerControlHitFrames.self) { controlFrames = $0 }
    }
    private func record(_ action: String) {
        last = action
        events += 1
    }
    private func controls(_ prefix: String) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Button { record("\(prefix).\(index)") } label: {
                    Image(systemName: "play.fill").playerControlTarget()
                }.buttonStyle(PlayerToolbarButtonStyle(selected: last == "\(prefix).\(index)")).accessibilityIdentifier("\(prefix).\(index)")
            }
        }.playerControlHitRegion()
    }
}

@main struct SearchInputChecksApp: App {
    @StateObject private var state = SearchInputState()
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("controls") { ControlHarness() }
            else if ProcessInfo.processInfo.arguments.contains("journal") { NavigationStack { JournalHarness() } }
            else { SearchInputHarness(state: state) }
        }
    }
}
