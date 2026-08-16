import Foundation
import Combine

// MARK: - 模型配置

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var provider: String          // openai / deepseek / anthropic / custom
    var baseURL: String           // https://api.openai.com/v1
    var apiKey: String
    var model: String             // gpt-4o-mini
    var isDefault: Bool = false
    var temperature: Double = 0.7
    var maxTokens: Int = 4096
}

final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published var configs: [ModelConfig] = []
    private let key = "trollmcp2.model_configs"

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ModelConfig].self, from: data) else { return }
        configs = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var defaultConfig: ModelConfig? {
        configs.first(where: { $0.isDefault }) ?? configs.first
    }

    func add(_ config: ModelConfig) {
        var c = config
        if c.isDefault {
            for i in configs.indices { configs[i].isDefault = false }
        }
        if configs.isEmpty { c.isDefault = true }
        configs.append(c)
        save()
    }

    func update(_ config: ModelConfig) {
        if config.isDefault {
            for i in configs.indices { configs[i].isDefault = (configs[i].id == config.id) }
        }
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        configs.remove(atOffsets: offsets)
        if !configs.contains(where: { $0.isDefault }) && !configs.isEmpty {
            configs[0].isDefault = true
        }
        save()
    }
}

// MARK: - 聊天消息

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var role: String         // user / assistant / system
    var content: String
    var timestamp: Date = Date()
    var isError: Bool = false
}

// MARK: - 会话管理

final class ConversationStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false

    func send(_ text: String, using config: ModelConfig) {
        let userMsg = ChatMessage(role: "user", content: text)
        messages.append(userMsg)
        isLoading = true

        let client = OpenAIClient(config)
        let history = messages.filter { !$0.isError }

        client.send(messages: history) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let response):
                    self.messages.append(ChatMessage(role: "assistant", content: response))
                case .failure(let error):
                    self.messages.append(ChatMessage(role: "assistant", content: "⚠️ \(error.localizedDescription)", isError: true))
                }
            }
        }
    }

    func clear() { messages.removeAll() }
}
