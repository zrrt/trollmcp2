import SwiftUI

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var editing: ModelConfig?
    @State private var isNewModel = false

    var body: some View {
        List {
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
                ForEach(store.configs) { cfg in
                    Button(action: { isNewModel = false; editing = cfg }) {
                        ModelRow(config: cfg)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { store.delete(at: $0) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("模型 API")
        .toolbar {
            Button(action: {
                isNewModel = true
                editing = ModelConfig(name: "", provider: "custom", apiProtocol: "OpenAI Chat Completions", baseURL: "", apiKey: "", model: "")
            }) {
                Image(systemName: "plus")
            }
        }
        .sheet(item: $editing, onDismiss: { editing = nil }) { cfg in
            // v2.9.14：改用 .sheet(item:) 绑定。iOS14 的 .sheet(isPresented:)+闭包捕获
            // 存在时序竞争——sheet 内容首次构建可能读到旧 editing(nil)，先用默认预设渲染，
            // 之后才切到真实配置（表现为"先显示 gpt-4o，很久才变成 5.6"）。
            // .sheet(item:) 在 item 变化时以新值重建内容，机制上消除该问题。
            ModelEditorView(config: isNewModel ? nil : cfg) { newCfg in
                if ModelStore.shared.configs.contains(where: { $0.id == newCfg.id }) {
                    ModelStore.shared.update(newCfg)
                } else {
                    ModelStore.shared.add(newCfg)
                }
            }
            .id(cfg.id)
        }
    }
}

struct ModelRow: View {
    let config: ModelConfig

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue)
                    .frame(width: 34, height: 34)
                Image(systemName: "cpu")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                        .font(.body)
                        .foregroundColor(.primary)
                    if config.isDefault {
                        Text("默认")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                Text("\(config.provider.capitalized) · \(config.model)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
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
            contextTokens: contextTokens
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
