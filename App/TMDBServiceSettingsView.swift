import SwiftUI
import TVCore

struct TMDBServiceSettingsView: View {
    @State private var config = TMDBServiceSettings.load()
    @State private var credential = TMDBServiceSettings.load().credential
    @State private var showTitleLogo = UserDefaults.standard.object(forKey: TMDBServiceSettings.titleLogoKey) as? Bool ?? true
    @State private var message: String?
    @State private var advanced = false
    @State private var clearRevision = 0

    var body: some View {
        SettingsPage(title: "TMDB 设置", symbol: "film.stack") {
            SettingsGroup(title: "TMDB") {
                SecureField("TMDB API Key 或 Read Access Token", text: $credential)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("tmdb.credential")
                TMDBEndpointRow(endpoint: .api, address: $config.apiBase, draft: draft)
                TMDBEndpointRow(endpoint: .image, address: $config.imageBase, draft: draft)
                HStack {
                    Text("清晰度")
                    Picker("清晰度", selection: $config.ultraHD) {
                        Text("高清").tag(false)
                        Text("原图").tag(true)
                    }.labelsHidden().pickerStyle(.menu)
                }
                Toggle("使用 TMDB 片名图标", isOn: $showTitleLogo)
                Text("开启后，首页轮播和详情页优先显示片名图标，首页竖图优先使用无字海报。")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup(config.proxyEnabled ? "高级设置（网络代理已开启）" : "高级设置", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("语言", text: $config.language, prompt: Text("zh-CN"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("使用网络代理", isOn: $config.proxyEnabled)
                        if config.proxyEnabled {
                            TextField("代理地址", text: $config.proxyUrl, prompt: Text("http://127.0.0.1:7890"))
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("代理账号（可选）", text: $config.proxyUsername)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("代理密码（可选）", text: $config.proxyPassword)
                        }
                        Button("恢复直连地址并关闭网络代理") {
                            config.useDirectConnection()
                            message = "已填入直连地址，可先测试，再保存。"
                        }
                    }.padding(.top, 8)
                }
                HStack(spacing: 20) {
                    Button("保存", action: save).settingsButton(prominent: true)
                    Button("清除", role: .destructive, action: clear).buttonStyle(.borderless)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            .id(clearRevision)
        }
    }

    private var draft: TMDBServiceSettings {
        config.editorConfiguration(credential: credential)
    }

    private func save() {
        do {
            let value = draft
            try value.save(showTitleLogo: showTitleLogo)
            config = TMDBServiceSettings.load()
            credential = config.credential
            message = config.custom == nil ? "已保存图片与显示设置。未填写密钥，影片资料使用内置服务。" : "已保存 TMDB 配置。"
        } catch { message = "保存失败，请检查 API、图片和网络代理地址。" }
    }

    private func clear() {
        TMDBServiceSettings.clear()
        config = TMDBServiceSettings()
        credential = ""
        showTitleLogo = true
        advanced = false
        clearRevision += 1
        message = "已清除 TMDB 配置，恢复内置服务。"
    }
}

private struct TMDBEndpointRow: View {
    enum Endpoint { case api, image }
    let endpoint: Endpoint
    @Binding var address: String
    let draft: TMDBServiceSettings
    @State private var attempt: UUID?
    @State private var result: String?
    @State private var testing = false

    private var title: String { endpoint == .api ? "API 代理地址" : "图片代理地址" }
    private var testInputs: [String] {
        [address, endpoint == .api ? draft.credential : "", endpoint == .api ? draft.language : String(draft.ultraHD),
         draft.proxyEnabled ? draft.proxyUrl : "",
         draft.proxyEnabled ? draft.proxyUsername : "", draft.proxyEnabled ? draft.proxyPassword : "",
         String(draft.proxyEnabled)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            HStack {
                TextField(title, text: $address, prompt: Text(endpoint == .api ? "https://api.tmdb.org" : TMDBServiceSettings.defaultImageBase))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(testing ? "测试中…" : "测试") {
                    result = nil
                    testing = true
                    attempt = UUID()
                }
                .buttonStyle(.borderless).frame(minWidth: 50, minHeight: 44).disabled(testing)
                .accessibilityLabel("测试" + title)
                .accessibilityIdentifier(endpoint == .api ? "tmdb.testAPI" : "tmdb.testImage")
            }
            if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
        }
        .task(id: attempt) {
            guard let id = attempt else { return }
            let feedback: String
            do {
                switch endpoint {
                case .api:
                    try await draft.testAPI()
                    feedback = "API 测试通过，已读取 TMDB 配置。"
                case .image:
                    try await draft.testImage()
                    feedback = "图片测试通过，已下载并解码海报。"
                }
            } catch {
                if endpoint == .image, let failure = error as? TMDBConnectionError, case let .http(code) = failure, code != 407 {
                    feedback = "图片服务返回 HTTP \(code)，请检查图片代理地址。"
                } else { feedback = TMDBConnectionError.message(for: error) }
            }
            guard !Task.isCancelled, attempt == id else { return }
            result = feedback
            testing = false
        }
        .appOnChange(of: testInputs) { _, _ in reset() }
        .onDisappear(perform: reset)
    }

    private func reset() {
        attempt = nil
        testing = false
        result = nil
    }
}
