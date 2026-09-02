import Foundation
import Combine

// MARK: - 模型配置

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var provider: String          // openai / deepseek / anthropic / custom
    var apiProtocol: String       // OpenAI Chat Completions / OpenAI Responses / Anthropic / Custom
    var baseURL: String           // https://api.openai.com/v1
    var apiKey: String
    var model: String             // gpt-4o-mini
    var authMethod: String        // Bearer / API Key / None
    var isDefault: Bool = false
    var temperature: Double = 0.7
    var maxTokens: Int = 2048
    /// v2.9.11：输入上下文预算（token 估算）。发送前按预算自动裁剪最旧消息，
    /// 避免长会话请求体无限增长导致"一直请求中"。
    var contextTokens: Int = 16000
    /// v2.8.4：中转站兼容级别（由 OpenAIClient 自适应降级时写入并持久化）
    /// 0=完整载荷 1=互换token参数名 2=去掉tool_choice 3=去掉tools纯对话 4=最小载荷
    var compatLevel: Int = 0

    init(id: UUID = UUID(), name: String, provider: String, apiProtocol: String = "OpenAI Chat Completions",
         baseURL: String, apiKey: String, model: String, authMethod: String = "Bearer",
         isDefault: Bool = false, temperature: Double = 0.7, maxTokens: Int = 2048, compatLevel: Int = 0,
         contextTokens: Int = 16000) {
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
        self.compatLevel = compatLevel
        self.contextTokens = contextTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        let decodedProtocol = (try? c.decode(String.self, forKey: .apiProtocol)) ?? "OpenAI Chat Completions"
        // v2.9.2：OpenAI Completions（旧版文本补全）已移除，旧配置迁移到 Chat Completions
        apiProtocol = decodedProtocol == "OpenAI Completions" ? "OpenAI Chat Completions" : decodedProtocol
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        let decodedAuthMethod = (try? c.decode(String.self, forKey: .authMethod)) ?? "Bearer"
        authMethod = decodedAuthMethod.trimmingCharacters(in: .whitespaces).isEmpty ? "Bearer" : decodedAuthMethod
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? 0.7
        maxTokens = (try? c.decode(Int.self, forKey: .maxTokens)) ?? 2048
        contextTokens = (try? c.decode(Int.self, forKey: .contextTokens)) ?? 16000
        compatLevel = (try? c.decode(Int.self, forKey: .compatLevel)) ?? 0
    }
}

// MARK: - 模型协议与鉴权方式

extension ModelConfig {
    static let apiProtocols = [
        "OpenAI Chat Completions",
        "OpenAI Responses",
        "Anthropic Messages",
        "Custom Endpoint"
    ]

    static let authMethods = ["Bearer", "API Key", "None"]

    static let providerPresets: [(name: String, provider: String, protocol: String, baseURL: String, model: String, auth: String)] = [
        ("OpenAI", "openai", "OpenAI Chat Completions", "https://api.openai.com/v1", "gpt-4o-mini", "Bearer"),
        ("DeepSeek", "deepseek", "OpenAI Chat Completions", "https://api.deepseek.com/v1", "deepseek-chat", "Bearer"),
        ("Anthropic", "anthropic", "Anthropic Messages", "https://api.anthropic.com/v1", "claude-3-5-sonnet-20240620", "API Key"),
        ("Botcf", "custom", "OpenAI Responses", "https://botcf.com/v1", "gpt-5.6-terra", "Bearer")
    ]

    /// 推理系列模型（GPT-5.x / o1 / o3 / o4）不接受 temperature 参数，
    /// 中转站会返回 "Invalid request parameter"。
    var sendsTemperature: Bool { !isReasoningModel && !model.lowercased().contains("reasoning") }

    /// v2.8.5：是否推理系列模型（GPT-5.x / o1 / o3 / o4）。
    /// 这类模型默认 reasoning_effort=medium，回复前会长时间思考（聊天转圈半天的主因），
    /// 请求时显式携带 reasoning_effort=none 提速。
    var isReasoningModel: Bool {
        let m = model.lowercased()
        let prefixes = ["gpt-5.", "o1", "o3", "o4", "o1-", "o3-", "o4-"]
        return prefixes.contains(where: { m.hasPrefix($0) }) || m.contains("reasoning")
    }

    /// 推理系列模型使用 max_completion_tokens 而非 max_tokens
    var maxTokensKey: String {
        let m = model.lowercased()
        let reasoningPrefixes = ["gpt-5.", "o1", "o3", "o4", "o1-", "o3-", "o4-"]
        if reasoningPrefixes.contains(where: { m.hasPrefix($0) }) { return "max_completion_tokens" }
        return "max_tokens"
    }
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
        // v2.9.0：支持 Responses API 协议
        let endpoint: String
        if config.apiProtocol == "Anthropic Messages" {
            endpoint = "/messages"
        } else if config.apiProtocol == "OpenAI Responses" {
            endpoint = "/responses"
        } else {
            endpoint = "/chat/completions"
        }
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        // v2.8.4：测试连接使用最小载荷（仅 model + messages）。
        // 旧版发送 max_completion_tokens=8，推理模型（gpt-5.x 默认 medium 推理）
        // 的推理 token 预算远超 8，会直接报参数错误，导致误判为连接失败。
        let body: [String: Any]
        if config.apiProtocol == "Anthropic Messages" {
            // Anthropic 协议要求必须传 max_tokens
            body = [
                "model": config.model,
                "max_tokens": 64,
                "messages": [["role": "user", "content": "hi"]]
            ]
        } else if config.apiProtocol == "OpenAI Responses" {
            body = [
                "model": config.model,
                "input": [["role": "user", "content": "hi"]]
            ]
        } else {
            body = [
                "model": config.model,
                "messages": [["role": "user", "content": "hi"]]
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
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "Bearer":
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case "API Key":
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case "None":
            break
        default:
            // 空/未知鉴权方式但填了 key 时，默认按 Bearer 发送（兼容旧配置或 UI 异常）
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
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
    /// v2.9.9：多模态附件。存 data URL（如 "data:image/jpeg;base64,..."）。
    /// 发送时若非空，OpenAIClient 把 content 序列化为多模态数组。
    var imageDataURLs: [String]? = nil

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
    /// v2.8.5：当前请求的实时状态文案（等待响应/降级重试中），展示在输入指示器旁
    @Published var statusText: String?
    /// v2.9.13：当前正在进行的 OpenAIClient（支持取消）
    private var currentClient: OpenAIClient?

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
        // v2.9.12：打开会话即视为"最近使用"，刷新 updatedAt 并重排到最前
        if selectedId != id, let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].updatedAt = Date()
        }
        selectedId = id
        sortAndSave()
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

    /// v2.9.13：取消当前进行中的请求（ChatView 停止按钮）
    func cancelCurrent() {
        currentClient?.cancel()
        currentClient = nil
        isLoading = false
        statusText = nil
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

    func send(_ text: String, using config: ModelConfig, imageDataURLs: [String]? = nil) {
        var msg = ChatMessage(role: "user", content: text)
        if let imgs = imageDataURLs, !imgs.isEmpty {
            msg.imageDataURLs = imgs
        }
        appendToCurrent(msg)
        isLoading = true

        // v2.9.16：渐进式披露——初始只带白名单工具 + tool_search 元工具，
        // 模型搜索命中后按需注入其余工具，避免 80+ 工具全量进请求导致慢/超时
        let baseTools = config.apiProtocol == "Anthropic Messages" ? nil : ToolRegistry.shared.enabledOpenAIToolSchema()
        runLoop(config: config, tools: baseTools, disclosed: [], depth: 0)
    }

    private func runLoop(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int) {
        guard depth < 6 else {
            isLoading = false
            statusText = nil
            appendToCurrent(ChatMessage(role: "assistant", content: "工具调用次数过多，已停止。", isError: true))
            return
        }

        // 动态合并：白名单 schema + 已披露工具的 schema（去重）
        var effectiveTools = tools
        if effectiveTools != nil, !disclosed.isEmpty {
            var existing = Set<String>()
            for t in effectiveTools ?? [] {
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String {
                    existing.insert(n)
                }
            }
            for name in disclosed {
                let apiName = name.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").inverted).joined(separator: "_")
                if existing.contains(apiName) { continue }
                if let schema = ToolRegistry.shared.openAISchema(for: name) {
                    effectiveTools?.append(schema)
                    existing.insert(apiName)
                }
            }
        }

        let client = OpenAIClient(config)
        currentClient = client
        var history = messagesForAPI(budget: config.contextTokens)
        // v2.9.19：默认开发者指令注入为 system 前缀（用户可自建并设为默认）
        if let devInstr = DeveloperInstructionStore.shared.defaultInjectionContent(), !devInstr.isEmpty {
            history.insert(ChatMessage(role: "system", content: "以下是开发者指令，请始终遵守：\n" + devInstr), at: 0)
        }

        client.send(messages: history, tools: effectiveTools, onStatus: { status in
            DispatchQueue.main.async { self.statusText = status }
        }) { result in
            DispatchQueue.main.async {
                self.statusText = nil
                switch result {
                case .success(.text(let text)):
                    self.isLoading = false
                    self.currentClient = nil
                    self.appendToCurrent(ChatMessage(role: "assistant", content: text))
                case .success(.toolCalls(let calls)):
                    let summary = calls.map { "调用工具 \($0.name)" }.joined(separator: "\n")
                    self.appendToCurrent(ChatMessage(role: "assistant", content: summary, toolCalls: calls))
                    var toolMessages: [ChatMessage] = []
                    var newlyDisclosed: [String] = []
                    for call in calls {
                        let params = Self.parseArgs(call.arguments)
                        do {
                            let r = try ToolRegistry.shared.dispatch(name: call.name, params: params)
                            let content = Self.jsonString(r)
                            toolMessages.append(ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name))
                            // v2.9.16：tool_search 命中后，把搜到的工具名加入待披露集合，
                            // 下一轮请求自动带上它们的完整 schema
                            if call.name == "tool_search" {
                                if let arr = r["tools"] as? [[String: Any]] {
                                    for item in arr {
                                        if let n = item["name"] as? String, !n.isEmpty {
                                            newlyDisclosed.append(n)
                                        }
                                    }
                                }
                            }
                        } catch {
                            toolMessages.append(ChatMessage(role: "tool", content: "error: \(error)", isError: true, toolCallId: call.id, toolName: call.name))
                        }
                    }
                    for tm in toolMessages { self.appendToCurrent(tm) }
                    let merged = Array(Set(disclosed + newlyDisclosed))
                    self.runLoop(config: config, tools: tools, disclosed: merged, depth: depth + 1)
                case .failure(let error):
                    self.isLoading = false
                    self.currentClient = nil
                    // v2.9.13：用户主动取消（-999）不追加错误气泡
                    let nsErr = error as NSError
                    if nsErr.code == -999 {
                        self.statusText = nil
                        return
                    }
                    self.appendToCurrent(ChatMessage(role: "assistant", content: "⚠️ \(error.localizedDescription)", isError: true))
                }
            }
        }
    }

    private func messagesForAPI(budget: Int) -> [ChatMessage] {
        let all = currentMessages.filter { !$0.isError }
        guard !all.isEmpty else { return all }
        let theBudget = budget
        // 估算总 token；低于预算直接返回（短会话）
        let total = all.reduce(0) { $0 + Self.estimateTokens($1) }
        if total <= budget { return all }
        // 长会话：从旧到新裁剪，但始终保留最后 N 条核心消息
        let keepMin = 6
        var kept: [ChatMessage] = []
        // 先保留最新 keepMin 条（含用户最新提问），其 token 计入预算
        let suffix = Array(all.suffix(keepMin))
        let prefix = Array(all.prefix(all.count - keepMin))
        var used = suffix.reduce(0) { $0 + Self.estimateTokens($1) }
        // 从旧到新累计到「预算 - suffix」内（v2.9.16：suffix 计入预算，避免超发）
        for m in prefix {
            let t = Self.estimateTokens(m)
            if used + t > budget { break }
            kept.append(m)
            used += t
        }
        var result = kept + suffix
        // 清理孤立 tool 消息：裁剪可能导致 assistant(tool_calls) 被裁、其 tool 结果残留
        result = Self.sanitizeToolSequence(result)
        // 插入截断提示
        let dropped = all.count - result.count
        if dropped > 0 {
            let hint = ChatMessage(role: "system", content: "[系统] 为控制上下文长度，已省略最早 \(dropped) 条历史消息。")
            result.insert(hint, at: 0)
        }
        return result
    }

    /// 粗估 token：中文/日文等约 1 字≈1.5 token；ASCII 约 4 字符≈1 token；图片按固定值计
    private static func estimateTokens(_ m: ChatMessage) -> Int {
        var t = 0
        let content = m.content
        var cjk = 0
        for ch in content.unicodeScalars {
            if (ch.value >= 0x4E00 && ch.value <= 0x9FFF) || (ch.value >= 0x3040 && ch.value <= 0x30FF) || (ch.value >= 0xAC00 && ch.value <= 0xD7AF) {
                cjk += 1
            }
        }
        let ascii = content.count - cjk
        t += Int(Double(cjk) * 1.5) + ascii / 4
        t += (m.imageDataURLs?.count ?? 0) * 600   // 每张图约 600 token（低分辨率近似）
        return max(t, 8)
    }

    /// 保证 assistant tool_calls 与其 tool 结果成对存在；删掉孤立的 tool 消息
    private static func sanitizeToolSequence(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var pendingToolCalls = false
        for m in msgs {
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                pendingToolCalls = true
                out.append(m)
            } else if m.role == "tool" {
                // 只有前面有未配对的 assistant tool_calls 才保留 tool 结果
                if pendingToolCalls {
                    out.append(m)
                }
                // 忽略孤立的 tool 消息
            } else {
                pendingToolCalls = false
                out.append(m)
            }
        }
        return out
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
