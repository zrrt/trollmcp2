import SwiftUI

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var showingEditor = false
    @State private var editing: ModelConfig?

    var body: some View {
        NavigationView {
            List {
                if store.configs.isEmpty {
                    Text("尚未添加模型配置")
                        .foregroundColor(.secondary)
                }
                ForEach(store.configs) { cfg in
                    Button(action: { editing = cfg }) {
                        ModelRow(config: cfg)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { store.delete(at: $0) }
            }
            .navigationTitle("模型配置")
            .toolbar {
                Button(action: { editing = nil; showingEditor = true }) {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showingEditor) {
                ModelEditorView(config: editing) { newCfg in
                    if let existing = editing {
                        store.update(newCfg)
                    } else {
                        store.add(newCfg)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct ModelRow: View {
    let config: ModelConfig

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(config.name).font(.headline)
                    if config.isDefault {
                        Text("默认")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                Text("\(config.provider) · \(config.model)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

struct ModelEditorView: View {
    @Environment(\.presentationMode) var presentationMode
    let config: ModelConfig?
    let onSave: (ModelConfig) -> Void

    @State private var name = ""
    @State private var provider = "openai"
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var apiKey = ""
    @State private var model = "gpt-4o-mini"
    @State private var isDefault = true
    @State private var temperature: Double = 0.7
    @State private var maxTokens: Int = 4096

    private let providers = ["openai", "deepseek", "anthropic", "custom"]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("基本信息")) {
                    TextField("名称", text: $name)
                    Picker("服务商", selection: $provider) {
                        ForEach(providers, id: \.self) { Text($0) }
                    }
                    Toggle("设为默认", isOn: $isDefault)
                }
                Section(header: Text("API 配置")) {
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    SecureField("API Key", text: $apiKey)
                    TextField("模型名", text: $model)
                        .autocapitalization(.none)
                }
                Section(header: Text("参数")) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                    Stepper("Max Tokens: \(maxTokens)", value: $maxTokens, in: 256...32768, step: 256)
                }
            }
            .navigationTitle(config == nil ? "添加模型" : "编辑模型")
            .toolbar {
                Button("取消") { presentationMode.wrappedValue.dismiss() }
                Button("保存") {
                    let cfg = ModelConfig(
                        id: config?.id ?? UUID(),
                        name: name.isEmpty ? model : name,
                        provider: provider,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        model: model,
                        isDefault: isDefault,
                        temperature: temperature,
                        maxTokens: maxTokens
                    )
                    onSave(cfg)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .onAppear {
                if let cfg = config {
                    name = cfg.name
                    provider = cfg.provider
                    baseURL = cfg.baseURL
                    apiKey = cfg.apiKey
                    model = cfg.model
                    isDefault = cfg.isDefault
                    temperature = cfg.temperature
                    maxTokens = cfg.maxTokens
                }
            }
        }
    }
}
