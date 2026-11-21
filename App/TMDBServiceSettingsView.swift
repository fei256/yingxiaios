import SwiftUI
import TVCore

struct TMDBServiceSettingsView: View {
    @State private var config = TMDBServiceSettings.load()
    @State private var message: String?
    @State private var credentialType = TMDBServiceSettings.load().token.isEmpty ? "apiKey" : "token"
    @State private var testTitle = "凡人修仙传"
    @State private var checks: [TMDBServiceSettings.ConnectionCheck] = []
    @State private var testTask: Task<Void, Never>?
    @State private var testing = false
    @State private var testRevision = UUID()
    var body: some View {
        SettingsPage(title: "TMDB", symbol: "film.stack") {
            SettingsGroup(footer: "默认使用内置 TMDB。关闭自定义后保留已填写的配置。") {
                Toggle("自定义 TMDB", isOn: $config.enabled)
                    .appOnChange(of: config.enabled) { _, enabled in if !enabled { save() } }
            }
            if config.enabled {
                SettingsGroup(title: "自定义 TMDB") {
                    Toggle("超清海报", isOn: $config.ultraHD)
                    Picker("凭据类型", selection: $credentialType) {
                        Text("API Key (v3)").tag("apiKey")
                        Text("Read Access Token").tag("token")
                    }
                    SecureField(credentialType == "token" ? "TMDB Read Access Token" : "TMDB API Key", text: credential)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !config.credential.isEmpty {
                        Button("清除已保存的密钥") { config.apiKey = ""; config.token = ""; message = "密钥将在保存后清除" }
                    }
                    TextField("语言", text: $config.language, prompt: Text("zh-CN"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("API 地址", text: $config.apiBase, prompt: Text(TMDBServiceSettings.defaultAPIBase))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("图片地址", text: $config.imageBase, prompt: Text(TMDBServiceSettings.defaultImageBase))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("使用代理", isOn: $config.proxyEnabled)
                    if config.proxyEnabled {
                        TextField("代理地址", text: $config.proxyUrl, prompt: Text("http://127.0.0.1:7890"))
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("代理账号（可选）", text: $config.proxyUsername)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("代理密码（可选）", text: $config.proxyPassword)
                        if !config.proxyPassword.isEmpty { Button("清除已保存的代理密码") { config.proxyPassword = ""; message = "代理密码将在保存后清除" } }
                        Text("支持 HTTP、HTTPS、SOCKS5；TMDB API 与图片使用相同代理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("保存 TMDB 设置", action: save).settingsButton(prominent: true)
                }
                SettingsGroup(title: "连接测试", footer: "使用当前填写的配置测试 API、影片资料和图片。修改后请保存设置，详情页会重新获取资料。") {
                    TextField("测试影片", text: $testTitle).autocorrectionDisabled()
                        .accessibilityIdentifier("tmdb.testTitle")
                    Button(action: testConnection) {
                        HStack { if testing { ProgressView() }; Text(testing ? "正在测试…" : "测试连接与图片") }
                    }.settingsButton(prominent: true).disabled(testing)
                        .accessibilityIdentifier("tmdb.testConnection")
                    if testing { Button("取消测试", action: cancelTest).accessibilityIdentifier("tmdb.cancelTest") }
                    ForEach(checks) { check in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(check.title, systemImage: check.status == .passed ? "checkmark.circle" : check.status == .warning ? "info.circle" : "exclamationmark.triangle")
                                .font(.subheadline.weight(.medium))
                            Text(check.message).font(.footnote).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
            if let message { SettingsGroup { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .onDisappear(perform: cancelTest)
        .appOnChange(of: config) { _, _ in cancelTest(); checks = [] }
    }
    private var credential: Binding<String> {
        Binding(get: { credentialType == "token" ? config.token : config.apiKey }, set: {
            if credentialType == "token" { config.token = $0; config.apiKey = "" }
            else { config.apiKey = $0; config.token = "" }
        })
    }
    private func save() {
        do {
            if credentialType == "token" { config.apiKey = "" }
            else { config.token = "" }
            try config.save()
            message = config.enabled ? "已保存自定义 TMDB，详情页将重新获取资料。可测试连接确认 API 和图片。" : "已使用内置 TMDB"
        } catch { message = "配置无效，请检查 API、图片和代理地址。" }
    }
    private func testConnection() {
        cancelTest(); checks = []; testing = true
        let revision = testRevision, draft = config, title = testTitle
        testTask = Task {
            do {
                let result = try await draft.testConnection(title: title)
                guard !Task.isCancelled, revision == testRevision else { return }
                checks = result
            } catch {
                guard !Task.isCancelled, revision == testRevision else { return }
                message = TMDBConnectionError.message(for: error)
            }
            guard revision == testRevision else { return }
            testing = false; testTask = nil
        }
    }
    private func cancelTest() {
        testRevision = UUID(); testTask?.cancel(); testTask = nil; testing = false
    }
}
