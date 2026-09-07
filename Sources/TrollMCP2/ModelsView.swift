import SwiftUI
import UIKit   // v2.9.85：UIPasteboard 复制推荐链接
import UniformTypeIdentifiers  // v2.9.107：配置导入/导出

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var editing: ModelConfig?
    @State private var isNewModel = false
    // v2.9.107：用量统计 / 导入导出
    @State private var showingUsage = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDoc: ConfigDoc?
    @State private var importMessage = ""
    @State private var showImportMessage = false

    var body: some View {
        List {
            // v2.9.85：推荐中转站卡片（作者自用 · 可复制链接）
            Section {
                RelayRecommendCard()
            }

            if store.configs.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("尚未添加模型配置")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 40)
                        Spacer()
                    }
                }
            } else {
                // v2.9.107：按分组展示（默认组优先，其余按字典序）
                let groups = groupedKeys()
                ForEach(groups, id: \.self) { g in
                    Section(header: HStack {
                        Text(g)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(count(in: g)) 个")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }) {
                        ForEach(configs(in: g)) { cfg in
                            ModelRow(config: cfg)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    isNewModel = false
                                    editing = cfg
                                }
                        }
                        .onDelete { offsets in delete(in: g, at: offsets) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("模型 API")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Button(action: { showingImporter = true }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("导入配置")
                Button(action: { exportDoc = ConfigDoc(text: store.exportJSON()); showingExporter = true }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("导出配置")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: { showingUsage = true }) {
                    Image(systemName: "chart.bar.fill")
                }
                .help("用量统计")
                Button(action: {
                    isNewModel = true
                    editing = ModelConfig(name: "", provider: "custom", apiProtocol: "OpenAI Chat Completions", baseURL: "", apiKey: "", model: "")
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingUsage) {
            UsageStatsView()
        }
        .sheet(item: $editing, onDismiss: { editing = nil }) { cfg in
            // v2.9.14：改用 .sheet(item:) 绑定。iOS14 的 .sheet(isPresented:)+闭包捕获
            // 存在时序竞争——sheet 内容首次构建可能读到旧 editing(nil)，先用默认预设渲染，
            // 之后才切到真实配置（表现为"先显示 gpt-4o，很久才变成 5.6"）。
            // .sheet(item:) 在 item 变化时以新值重建内容，机制上消除该问题。
            // 注：iOS 14.0-14.4 多 sheet 只生效最后一个声明，因此编辑弹窗必须放最后。
            ModelEditorView(config: isNewModel ? nil : cfg) { newCfg in
                if ModelStore.shared.configs.contains(where: { $0.id == newCfg.id }) {
                    ModelStore.shared.update(newCfg)
                } else {
                    ModelStore.shared.add(newCfg)
                }
            }
            .id(cfg.id)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        let r = store.importJSON(text)
                        if r.failed > 0 {
                            importMessage = "导入完成：成功 \(r.ok) 个，失败 \(r.failed) 个"
                        } else {
                            importMessage = "导入完成：成功 \(r.ok) 个"
                        }
                    } else {
                        importMessage = "无法读取所选文件"
                    }
                } else {
                    importMessage = "无法访问所选文件"
                }
            case .failure:
                importMessage = "已取消导入"
            }
            showImportMessage = true
        }
        .fileExporter(isPresented: $showingExporter, document: exportDoc, contentType: .json, defaultFilename: "TrollAgent-models-\(Date().timeIntervalSince1970)") { _ in }
        .alert(isPresented: $showImportMessage) {
            Alert(title: Text("模型配置导入"), message: Text(importMessage), dismissButton: .default(Text("好")))
        }
    }

    // MARK: v2.9.107 分组辅助

    private func groupedKeys() -> [String] {
        var seen: [String] = []
        for c in store.configs where !seen.contains(c.group) { seen.append(c.group) }
        return seen.sorted {
            if $0 == "默认" { return true }
            if $1 == "默认" { return false }
            return $0 < $1
        }
    }

    private func configs(in group: String) -> [ModelConfig] {
        store.configs.filter { $0.group == group }
    }

    private func count(in group: String) -> Int {
        store.configs.filter { $0.group == group }.count
    }

    private func delete(in group: String, at offsets: IndexSet) {
        for i in offsets {
            let list = configs(in: group)
            if i < list.count, let idx = store.configs.firstIndex(where: { $0.id == list[i].id }) {
                store.delete(at: IndexSet(integer: idx))
            }
        }
    }
}

struct ModelRow: View {
    let config: ModelConfig
    // v2.9.107：行内测速 + 熔断状态 + 一键切换
    @State private var testing = false
    @State private var latencyText = ""
    @State private var latencyColor: Color = .secondary

    var body: some View {
        let info = ModelStore.shared.breaker(for: config.id).stateInfo
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconColor(for: info.state))
                    .frame(width: 34, height: 34)
                Image(systemName: info.state == .open ? "bolt.slash" : "cpu")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if config.isDefault {
                        Text("默认")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    if info.state != .closed {
                        Text(info.state.label)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(iconColor(for: info.state).opacity(0.15))
                            .foregroundColor(iconColor(for: info.state))
                            .cornerRadius(4)
                    }
                }
                Text("\(config.provider.capitalized) · \(config.model)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !latencyText.isEmpty {
                    Text(latencyText)
                        .font(.caption2)
                        .foregroundColor(latencyColor)
                }
            }
            Spacer()
            Button(action: speedTest) {
                if testing {
                    ProgressView()
                } else {
                    Image(systemName: "gauge")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(testing)
            if !config.isDefault {
                Button(action: activate) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func iconColor(for state: CircuitState) -> Color {
        switch state {
        case .closed: return Color.blue
        case .halfOpen: return Color.orange
        case .open: return Color.red
        }
    }

    /// v2.9.107：一键切换为当前使用模型
    private func activate() {
        var c = config
        c.isDefault = true
        ModelStore.shared.update(c)
        ModelStore.shared.markUsed(config.id.uuidString)
        ModelStore.shared.breaker(for: config.id).reset()
    }

    /// v2.9.107：供应商测速（GET /models，8s 超时）
    private func speedTest() {
        testing = true
        latencyText = ""
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            latencyText = "Base URL 无效"
            latencyColor = .red
            testing = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.authMethod == "API Key" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, _, error in
            DispatchQueue.main.async {
                testing = false
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if error != nil {
                    latencyText = "测速失败 · \(ms)ms"
                    latencyColor = .red
                } else {
                    latencyText = "延迟 \(ms)ms"
                    latencyColor = ms < 500 ? .green : (ms < 2000 ? .orange : .red)
                }
            }
        }.resume()
    }
}

// MARK: - v2.9.85 推荐中转站卡片（作者自用 · 链接可复制）

struct RelayRecommendCard: View {
    @State private var copied = false
    private let link = "https://china.botcf.com/register?aff=bJMk"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(L10n.t("relay_card_title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
            }
            Text(L10n.t("relay_card_body"))
                .font(.caption)
                .foregroundColor(.white.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(link)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = link
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }) {
                    Label(copied ? L10n.t("relay_card_copied") : L10n.t("relay_card_copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .foregroundColor(copied ? .white : Color(red: 0.82, green: 0.95, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.44, blue: 0.92), Color(red: 0.0, green: 0.74, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(14)
    }
}

// MARK: - 模型 API 编辑器（原版风格）

struct ModelEditorView: View {
    @Environment(\.presentationMode) var presentationMode
    let config: ModelConfig?
    let onSave: (ModelConfig) -> Void

    @State private var name: String
    @State private var provider: String
    @State private var apiProtocol: String
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var model: String
    @State private var authMethod: String
    @State private var isDefault: Bool
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var contextTokens: Int
    @State private var group: String

    @State private var showKey = false
    @State private var showingQuickPicker = false
    @State private var testStatus = ""
    @State private var testColor: Color = .secondary
    @State private var isTesting = false
    @State private var fetchedModels: [String] = []
    @State private var showingModelPicker = false
    @State private var savedFlag = false

    private let providers = ["openai", "deepseek", "anthropic", "custom"]

    // 在 init 中一次性初始化，避免 iOS 14 上 .onAppear 重复触发把用户输入冲回默认值
    init(config: ModelConfig?, onSave: @escaping (ModelConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        let p = ModelConfig.providerPresets.first
        _name = State(initialValue: config?.name ?? (p?.name ?? ""))
        _provider = State(initialValue: config?.provider ?? (p?.provider ?? "custom"))
        _apiProtocol = State(initialValue: config?.apiProtocol ?? (p?.protocol ?? "OpenAI Chat Completions"))
        _baseURL = State(initialValue: config?.baseURL ?? (p?.baseURL ?? ""))
        _apiKey = State(initialValue: config?.apiKey ?? "")
        _model = State(initialValue: config?.model ?? (p?.model ?? ""))
        _authMethod = State(initialValue: config?.authMethod ?? (p?.auth ?? "Bearer"))
        _isDefault = State(initialValue: config?.isDefault ?? false)
        _temperature = State(initialValue: config?.temperature ?? 0.7)
        _maxTokens = State(initialValue: config?.maxTokens ?? 2048)
        _contextTokens = State(initialValue: config?.contextTokens ?? 16000)
        _group = State(initialValue: config?.group ?? "默认")
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: sectionHeader(apiProtocol.uppercased())) {
                    quickConfigRow
                    editorRow("名称", text: $name, placeholder: "Botcf")
                    pickerRow("API 协议", selection: $apiProtocol, options: ModelConfig.apiProtocols)
                }

                Section(header: sectionHeader("API 配置")) {
                    editorRow("Base URL", text: $baseURL, placeholder: "https://botcf.com/v1")
                    editorRow("模型名", text: $model, placeholder: "gpt-5.6-terra")
                    pickerRow("鉴权方式", selection: $authMethod, options: ModelConfig.authMethods)
                    tokenRow
                    // v2.9.107：供应商分组（管理页按分组折叠展示）
                    editorRow("分组", text: $group, placeholder: "默认")
                }

                Section(header: sectionHeader("参数")) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                    Stepper("Max Tokens: \(maxTokens)", value: $maxTokens, in: 256...32768, step: 256)
                    Stepper("上下文预算: \(contextTokens)", value: $contextTokens, in: 4000...128000, step: 2000)
                }
                Section(header: sectionHeader("参数说明")) {
                    Text("Max Tokens：单次回复最多生成的 token 数（输出上限，不限制上下文）。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("上下文预算：发送给模型的上下文 token 上限。会话超出时自动裁剪最早的历史消息（保留最近对话），避免长会话请求过大变慢或超时。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("提速提示：Max Tokens 是输出上限，值越大模型单次生成越长、等待越久。日常对话 2048 已够用；若回复慢，可调低 Max Tokens 或上下文预算。")
                        .font(.caption)
                        .foregroundColor(.blue)
                }

                Section(header: sectionHeader("操作")) {
                    Button(action: fetchUpstreamModels) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                            Text("获取上游模型列表")
                                .foregroundColor(.blue)
                            Spacer()
                            if isTesting && fetchedModels.isEmpty {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)

                    Button(action: saveOnly) {
                        Text("保存修改")
                            .foregroundColor(.blue)
                    }

                    Button(action: saveAndTest) {
                        HStack {
                            Text("保存并测试连接")
                                .foregroundColor(.blue)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                    // v2.9.107：测速（只测延迟，不保存）
                    Button(action: speedTestOnly) {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge")
                                .font(.system(size: 20))
                                .foregroundColor(.orange)
                            Text("测试接口延迟")
                                .foregroundColor(.orange)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                }

                if savedFlag {
                    Section(header: sectionHeader("状态")) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("已保存到本机")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }

                if !testStatus.isEmpty {
                    Section(header: sectionHeader("连接测试")) {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundColor(testColor)
                    }
                }

                Section(header: sectionHeader("说明")) {
                    Text("适用于 OpenAI、DeepSeek OpenAI 格式和多数兼容网关。Base URL 通常以 /v1 结尾。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(config == nil ? "添加模型" : name)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { saveOnly() }
                }
            }
            .sheet(isPresented: $showingQuickPicker) {
                QuickConfigPicker { applyPreset(name: $0) }
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerSheet(models: fetchedModels, selected: $model)
            }
        }
    }

    // MARK: - 子视图

    private var quickConfigRow: some View {
        Button(action: { showingQuickPicker = true }) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
                Text("供应商快速配置")
                    .foregroundColor(.blue)
                Spacer()
            }
        }
    }

    private func editorRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
    }

    private func pickerRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .frame(maxWidth: 220)
            .labelsHidden()
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(authMethod == "None" ? "无需鉴权" : "\(authMethod) Token")
                    .font(.body)
                if showKey {
                    TextField("sk-...", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } else {
                    SecureField("sk-...", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Spacer()
            Button(action: { showKey.toggle() }) {
                Image(systemName: showKey ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }

    // MARK: - 操作

    private func applyPreset(at index: Int) {
        let p = ModelConfig.providerPresets[min(index, ModelConfig.providerPresets.count - 1)]
        name = p.name
        provider = p.provider
        apiProtocol = p.protocol
        baseURL = p.baseURL
        model = p.model
        authMethod = p.auth
    }

    private func applyPreset(name presetName: String) {
        if let p = ModelConfig.providerPresets.first(where: { $0.name == presetName }) {
            name = p.name
            provider = p.provider
            apiProtocol = p.protocol
            baseURL = p.baseURL
            model = p.model
            authMethod = p.auth
        }
    }

    private func makeConfig() -> ModelConfig {
        ModelConfig(
            id: config?.id ?? UUID(),
            name: name.isEmpty ? model : name,
            provider: provider,
            apiProtocol: apiProtocol,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            authMethod: authMethod,
            isDefault: isDefault,
            temperature: temperature,
            maxTokens: maxTokens,
            contextTokens: contextTokens,
            group: group
        )
    }

    private func saveOnly() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        presentationMode.wrappedValue.dismiss()
    }

    private func saveAndTest() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        isTesting = true
        testStatus = "正在测试..."
        testColor = .secondary
        ModelAPIClient.shared.testConnection(config: cfg) { result in
            isTesting = false
            switch result {
            case .success(let msg):
                testStatus = msg
                testColor = .green
            case .failure(let error):
                testStatus = error.localizedDescription
                testColor = .red
            }
        }
    }

    private func fetchUpstreamModels() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        isTesting = true
        testStatus = "正在获取模型列表..."
        testColor = .secondary
        ModelAPIClient.shared.fetchModelList(config: cfg) { result in
            isTesting = false
            switch result {
            case .success(let models):
                fetchedModels = models
                if models.isEmpty {
                    testStatus = "未返回任何模型"
                    testColor = .orange
                } else {
                    testStatus = "获取到 \(models.count) 个模型"
                    testColor = .green
                    showingModelPicker = true
                }
            case .failure(let error):
                testStatus = error
                testColor = .red
            }
        }
    }

    /// v2.9.107：只测接口延迟（不保存）
    private func speedTestOnly() {
        isTesting = true
        testStatus = "正在测速..."
        testColor = .secondary
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            isTesting = false
            testStatus = "Base URL 无效"
            testColor = .red
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if authMethod == "API Key" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, _, error in
            DispatchQueue.main.async {
                isTesting = false
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if error != nil {
                    testStatus = "测速失败 · \(ms)ms"
                    testColor = .red
                } else {
                    testStatus = "接口延迟 \(ms)ms"
                    testColor = ms < 500 ? .green : (ms < 2000 ? .orange : .red)
                }
            }
        }.resume()
    }
}

// MARK: - 快速配置选择器

struct QuickConfigPicker: View {
    @Environment(\.presentationMode) var presentationMode
    let onSelect: (String) -> Void

    var body: some View {
        NavigationView {
            List(ModelConfig.providerPresets, id: \.name) { preset in
                Button(action: {
                    onSelect(preset.name)
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.blue)
                                .frame(width: 34, height: 34)
                            Image(systemName: "sparkles")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.body)
                            Text("\(preset.protocol) · \(preset.baseURL)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("供应商快速配置")
            .toolbar {
                Button("关闭") { presentationMode.wrappedValue.dismiss() }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 模型选择 Sheet

struct ModelPickerSheet: View {
    let models: [String]
    @Binding var selected: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List(models, id: \.self) { m in
                Button(action: {
                    selected = m
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Text(m)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        if selected == m {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择模型")
            .toolbar {
                Button("关闭") { presentationMode.wrappedValue.dismiss() }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - v2.9.107 配置导入导出（FileDocument）

struct ConfigDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - v2.9.107 用量统计页（聚合本地 usage.jsonl）

struct UsageStatsView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var records: [[String: Any]] = []

    var body: some View {
        NavigationView {
            List {
                let agg = aggregate()
                Section(header: Text("总览")) {
                    HStack {
                        statCell(title: "请求数", value: "\(agg.total)", color: .blue)
                        statCell(title: "成功率", value: agg.total > 0 ? "\(Int(Double(agg.ok) / Double(agg.total) * 100))%" : "-", color: .green)
                        statCell(title: "平均耗时", value: agg.total > 0 ? "\(agg.elapsed / agg.total)ms" : "-", color: .orange)
                        statCell(title: "输入 token 估算", value: "\(fmtK(agg.inputTokens))", color: .purple)
                    }
                }

                if !agg.byProvider.isEmpty {
                    Section(header: Text("按供应商")) {
                        ForEach(agg.byProvider.sorted(by: { $0.total > $1.total }), id: \.self) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.name).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(row.total) 次 · 成功 \(row.ok)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                ProgressView(value: row.total > 0 ? Double(row.ok) / Double(row.total) : 0)
                                    .accentColor(.green)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !records.isEmpty {
                    Section(header: Text("最近请求（最多 30 条）")) {
                        ForEach(0..<min(records.count, 30), id: \.self) { i in
                            requestRow(records[i])
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("用量统计")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清除记录") {
                        UsageRecorder.shared.clear()
                        records = []
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .onAppear { records = UsageRecorder.shared.records }
        }
    }

    private func fmtK(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }

    private func statCell(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func requestRow(_ r: [String: Any]) -> some View {
        let ts = r["ts"] as? Double ?? 0
        let ok = r["ok"] as? Bool ?? false
        let el = r["elapsedMs"] as? Int ?? 0
        let name = r["name"] as? String ?? "-"
        let model = r["model"] as? String ?? "-"
        let error = r["error"] as? String ?? ""
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(ok ? .green : .red)
                    .font(.system(size: 13))
                Text(name).font(.subheadline).lineLimit(1)
                Spacer()
                Text("\(el)ms").font(.caption).foregroundColor(.secondary)
                Text(f.string(from: d)).font(.caption2).foregroundColor(.secondary)
            }
            Text(model).font(.caption).foregroundColor(.secondary).lineLimit(1)
            if !ok, !error.isEmpty {
                Text(error).font(.caption2).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private struct ProviderAgg: Hashable {
        let name: String
        var total: Int = 0
        var ok: Int = 0
        var elapsed: Int = 0
        var inputTokens: Int = 0
    }

    private func aggregate() -> (total: Int, ok: Int, elapsed: Int, inputTokens: Int, byProvider: [ProviderAgg]) {
        var total = 0, ok = 0, elapsed = 0, inputTokens = 0
        var map: [String: ProviderAgg] = [:]
        for r in records {
            total += 1
            let o = r["ok"] as? Bool ?? false
            if o { ok += 1 }
            elapsed += r["elapsedMs"] as? Int ?? 0
            inputTokens += r["estInputTokens"] as? Int ?? 0
            let name = r["name"] as? String ?? "-"
            var a = map[name] ?? ProviderAgg(name: name)
            a.total += 1
            if o { a.ok += 1 }
            a.elapsed += r["elapsedMs"] as? Int ?? 0
            a.inputTokens += r["estInputTokens"] as? Int ?? 0
            map[name] = a
        }
        return (total, ok, elapsed, inputTokens, Array(map.values))
    }
}
