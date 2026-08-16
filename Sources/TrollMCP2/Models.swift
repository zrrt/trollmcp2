import Foundation
import Combine

// MARK: - 模型配置

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var provider: String          // openai / deepseek / anthropic / custom
    var apiProtocol: String       // OpenAI Chat Completions / OpenAI Completions / Anthropic / Custom
    var baseURL: String           // https://api.openai.com/v1
    var apiKey: String
    var model: String             // gpt-4o-mini
    var authMethod: String        // Bearer / API Key / None
    var isDefault: Bool = false
    var temperature: Double = 0.7
    var maxTokens: Int = 4096

    init(id: UUID = UUID(), name: String, provider: String, apiProtocol: String = "OpenAI Chat Completions",
         baseURL: String, apiKey: String, model: String, authMethod: String = "Bearer",
         isDefault: Bool = false, temperature: Double = 0.7, maxTokens: Int = 4096) {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.authMethod = authMethod
        self.isDefault = isDefault
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        apiProtocol = (try? c.decode(String.self, forKey: .apiProtocol)) ?? "OpenAI Chat Completions"
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        authMethod = (try? c.decode(String.self, forKey: .authMethod)) ?? "Bearer"
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? 0.7
        maxTokens = (try? c.decode(Int.self, forKey: .maxTokens)) ?? 4096
    }
}

// MARK: - 模型协议与鉴权方式

extension ModelConfig {
    static let apiProtocols = [
        "OpenAI Chat Completions",
        "OpenAI Completions",
        "Anthropic Messages",
        "Custom Endpoint"
    ]

    static let authMethods = ["Bearer", "API Key", "None"]

    static let providerPresets: [(name: String, provider: String, protocol: String, baseURL: String, model: String, auth: String)] = [
        ("OpenAI", "openai", "OpenAI Chat Completions", "https://api.openai.com/v1", "gpt-4o-mini", "Bearer"),
        ("DeepSeek", "deepseek", "OpenAI Chat Completions", "https://api.deepseek.com/v1", "deepseek-chat", "Bearer"),
        ("Anthropic", "anthropic", "Anthropic Messages", "https://api.anthropic.com/v1", "claude-3-5-sonnet-20240620", "API Key"),
        ("Botcf", "custom", "OpenAI Chat Completions", "https://botcf.com/v1", "gpt-5.6-terra", "Bearer")
    ]
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

// MARK: - 模型列表获取与连接测试

enum ModelListResult {
    case success([String])
    case failure(String)
}

final class ModelAPIClient {
    static let shared = ModelAPIClient()

    func fetchModelList(config: ModelConfig, completion: @escaping (ModelListResult) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            completion(.failure("无效的 Base URL"))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        applyAuth(config: config, to: &request)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error.localizedDescription))
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["data"] as? [[String: Any]] else {
                    let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
                    completion(.failure("解析失败: \(raw.prefix(200))"))
                    return
                }
                let ids = models.compactMap { $0["id"] as? String }.sorted()
                completion(.success(ids))
            }
        }.resume()
    }

    func testConnection(config: ModelConfig, completion: @escaping (Result<String, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = config.apiProtocol == "Anthropic Messages" ? "/messages" : "/chat/completions"
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        let body: [String: Any]
        if config.apiProtocol == "Anthropic Messages" {
            body = [
                "model": config.model,
                "max_tokens": min(config.maxTokens, 8),
                "messages": [["role": "user", "content": "hi"]]
            ]
        } else {
            body = [
                "model": config.model,
                "messages": [["role": "user", "content": "hi"]],
                "max_tokens": min(config.maxTokens, 8)
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if (200...299).contains(http.statusCode) {
                        completion(.success("连接成功 (HTTP \(http.statusCode))"))
                    } else {
                        let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        completion(.failure(NSError(domain: "ModelAPIClient", code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw.prefix(200))"])))
                    }
                } else {
                    completion(.success("已收到响应"))
                }
            }
        }.resume()
    }

    private func applyAuth(config: ModelConfig, to request: inout URLRequest) {
        switch config.authMethod {
        case "Bearer":
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        case "API Key":
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        default:
            break
        }
    }
}

// MARK: - 聊天消息

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: String
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var role: String         // user / assistant / system / tool
    var content: String
    var timestamp: Date = Date()
    var isError: Bool = false
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var toolName: String?

    var isTool: Bool { role == "tool" }
}

// MARK: - 单个会话

struct ChatConversation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
}

// MARK: - 会话管理

final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published var conversations: [ChatConversation] = []
    @Published var selectedId: UUID?
    @Published var isLoading = false

    private let key = "trollmcp2.conversations"

    init() { load() }

    var selectedIndex: Int? {
        conversations.firstIndex { $0.id == selectedId }
    }

    var currentMessages: [ChatMessage] {
        guard let idx = selectedIndex else { return [] }
        return conversations[idx].messages
    }

    var currentTitle: String {
        guard let idx = selectedIndex else { return "会话" }
        return conversations[idx].title
    }

    func newConversation(title: String = "新会话") {
        let conv = ChatConversation(title: title, createdAt: Date(), updatedAt: Date(), messages: [])
        conversations.insert(conv, at: 0)
        selectedId = conv.id
        save()
    }

    func select(_ id: UUID) {
        selectedId = id
        save()
    }

    func appendToCurrent(_ message: ChatMessage) {
        guard let idx = selectedIndex else { return }
        var conv = conversations[idx]
        if conv.messages.isEmpty {
            conv.title = title(from: message.content)
        }
        conv.messages.append(message)
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
    }

    func clearCurrent() {
        guard let idx = selectedIndex else { return }
        var conv = conversations[idx]
        conv.messages.removeAll()
        conv.title = "新会话"
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
    }

    func delete(at offsets: IndexSet) {
        conversations.remove(atOffsets: offsets)
        if selectedId != nil && !conversations.contains(where: { $0.id == selectedId }) {
            selectedId = conversations.first?.id
        }
        sortAndSave()
    }

    func send(_ text: String, using config: ModelConfig) {
        appendToCurrent(ChatMessage(role: "user", content: text))
        isLoading = true

        let tools = config.apiProtocol == "Anthropic Messages" ? nil : ToolRegistry.shared.enabledDefinitions.openAIToolSchema()
        runLoop(config: config, tools: tools, depth: 0)
    }

    private func runLoop(config: ModelConfig, tools: [[String: Any]]?, depth: Int) {
        guard depth < 6 else {
            isLoading = false
            appendToCurrent(ChatMessage(role: "assistant", content: "工具调用次数过多，已停止。", isError: true))
            return
        }

        let client = OpenAIClient(config)
        let history = messagesForAPI()

        client.send(messages: history, tools: tools) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(.text(let text)):
                    self.isLoading = false
                    self.appendToCurrent(ChatMessage(role: "assistant", content: text))
                case .success(.toolCalls(let calls)):
                    let summary = calls.map { "调用工具 \($0.name)" }.joined(separator: "\n")
                    self.appendToCurrent(ChatMessage(role: "assistant", content: summary, toolCalls: calls))
                    var toolMessages: [ChatMessage] = []
                    for call in calls {
                        let params = Self.parseArgs(call.arguments)
                        do {
                            let r = try ToolRegistry.shared.dispatch(name: call.name, params: params)
                            let content = Self.jsonString(r)
                            toolMessages.append(ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name))
                        } catch {
                            toolMessages.append(ChatMessage(role: "tool", content: "error: \(error)", isError: true, toolCallId: call.id, toolName: call.name))
                        }
                    }
                    for tm in toolMessages { self.appendToCurrent(tm) }
                    self.runLoop(config: config, tools: tools, depth: depth + 1)
                case .failure(let error):
                    self.isLoading = false
                    self.appendToCurrent(ChatMessage(role: "assistant", content: "⚠️ \(error.localizedDescription)", isError: true))
                }
            }
        }
    }

    private func messagesForAPI() -> [ChatMessage] {
        currentMessages.filter { !$0.isError }
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func sortAndSave() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    private func title(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return String(line.prefix(30))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ChatConversation].self, from: data),
           !decoded.isEmpty {
            conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
            selectedId = conversations.first?.id
            return
        }

        // 从旧版单一会话记录迁移
        if let oldData = UserDefaults.standard.data(forKey: "trollmcp2.transcript"),
           let messages = try? JSONDecoder().decode([ChatMessage].self, from: oldData),
           !messages.isEmpty {
            let first = messages.first!
            let title = String(first.content.prefix(30))
            let conv = ChatConversation(
                title: title,
                createdAt: first.timestamp,
                updatedAt: messages.last?.timestamp ?? Date(),
                messages: messages
            )
            conversations = [conv]
            selectedId = conv.id
            save()
            UserDefaults.standard.removeObject(forKey: "trollmcp2.transcript")
        } else {
            newConversation()
        }
    }
}
