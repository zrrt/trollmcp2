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
    /// v2.9.107：分组名（供应商分组管理，对齐 cc-switch provider groups）
    var group: String = "默认"

    init(id: UUID = UUID(), name: String, provider: String, apiProtocol: String = "OpenAI Chat Completions",
         baseURL: String, apiKey: String, model: String, authMethod: String = "Bearer",
         isDefault: Bool = false, temperature: Double = 0.7, maxTokens: Int = 2048, compatLevel: Int = 0,
         contextTokens: Int = 16000, group: String = "默认") {
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
        self.group = group
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
        group = (try? c.decode(String.self, forKey: .group)) ?? "默认"
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
    // v2.9.97：记住最近一次使用的模型，顶栏立即显示用户上次用的配置，不再回退到第一个（旧 gpt4o）
    private let lastUsedKey = "trollmcp2.last_used_config_id"

    init() { load() }

    var lastUsedConfigId: String? {
        get { UserDefaults.standard.string(forKey: lastUsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastUsedKey) }
    }

    func markUsed(_ id: String) {
        lastUsedConfigId = id
    }

    func load() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ModelConfig].self, from: data) else {
            // v2.9.107：主数据损坏时从备份恢复（最多试 4 份）
            for i in 0...3 {
                if let bak = ud.data(forKey: "\(key).bak.\(i)"),
                   let decoded = try? JSONDecoder().decode([ModelConfig].self, from: bak) {
                    configs = decoded
                    break
                }
            }
            return
        }
        configs = decoded
    }

    /// v2.9.107：原子写前备份轮换（保留最近 4 份）
    private func rotateBackup() {
        let ud = UserDefaults.standard
        guard let current = ud.data(forKey: key) else { return }
        for i in stride(from: 2, through: 0, by: -1) {
            if let old = ud.data(forKey: "\(key).bak.\(i)") {
                ud.set(old, forKey: "\(key).bak.\(i + 1)")
            }
        }
        ud.set(current, forKey: "\(key).bak.0")
    }

    func save() {
        if let data = try? JSONEncoder().encode(configs) {
            rotateBackup()
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: v2.9.107 —— 熔断器注册表（运行时，不持久化；对齐 cc-switch circuit_breaker）

    private(set) var breakers: [UUID: CircuitBreaker] = [:]

    func breaker(for id: UUID) -> CircuitBreaker {
        if let b = breakers[id] { return b }
        let b = CircuitBreaker(name: configs.first { $0.id == id }?.name ?? "model")
        breakers[id] = b
        return b
    }

    // MARK: v2.9.107 —— 配置导入 / 导出（对齐 cc-switch import/export）

    func exportJSON() -> String {
        var items: [Any] = []
        for c in configs {
            if let d = try? JSONEncoder().encode(c),
               let obj = try? JSONSerialization.jsonObject(with: d) {
                items.append(obj)
            }
        }
        let payload: [String: Any] = [
            "app": "TrollAgent", "type": "model_configs", "version": 1,
            "exportedAt": Int(Date().timeIntervalSince1970),
            "configs": items
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return ""
    }

    @discardableResult
    func importJSON(_ text: String) -> (ok: Int, failed: Int) {
        guard let data = text.data(using: .utf8) else { return (0, 0) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["configs"] as? [[String: Any]] {
            var ok = 0, failed = 0
            for item in arr {
                if let d = try? JSONSerialization.data(withJSONObject: item),
                   let c = try? JSONDecoder().decode(ModelConfig.self, from: d) {
                    add(c); ok += 1
                } else { failed += 1 }
            }
            return (ok, failed)
        }
        // 兼容纯数组
        if let arr = try? JSONDecoder().decode([ModelConfig].self, from: data) {
            for c in arr { add(c) }
            return (arr.count, 0)
        }
        return (0, 0)
    }

    var defaultConfig: ModelConfig? {
        if let d = configs.first(where: { $0.isDefault }) { return d }
        // v2.9.97：其次取最近使用，最后回退第一个
        if let last = lastUsedConfigId, let m = configs.first(where: { $0.id.uuidString == last }) {
            return m
        }
        return configs.first
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


    // v2.9.100：通用轻量 chat 调用（AI 分析引擎等内部工具用）。
    // 按 apiProtocol 自动选端点（chat/completions / responses / messages），不触发工具循环。
    func sendChat(config: ModelConfig, messages: [[String: Any]],
                  timeout: TimeInterval = 90,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint: String
        if config.apiProtocol == "Anthropic Messages" {
            endpoint = "/messages"
        } else if config.apiProtocol == "OpenAI Responses" {
            endpoint = "/responses"
        } else {
            endpoint = "/chat/completions"
        }
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "无效的 Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        let body: [String: Any]
        if config.apiProtocol == "Anthropic Messages" {
            body = ["model": config.model, "max_tokens": 4096, "messages": messages]
        } else if config.apiProtocol == "OpenAI Responses" {
            var msgs: [[String: Any]] = []
            for m in messages {
                msgs.append([
                    "role": (m["role"] as? String) ?? "user",
                    "content": [[ "type": "input_text", "text": (m["content"] as? String) ?? "" ]]
                ])
            }
            body = ["model": config.model, "input": msgs]
        } else {
            body = ["model": config.model, "messages": messages, "temperature": 0.3]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                                userInfo: [NSLocalizedDescriptionKey: "无返回数据"])))
                    return
                }
                var text = ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let msg = first["message"] as? [String: Any],
                       let content = msg["content"] as? String {
                        text = content
                    } else if let output = json["output"] as? [[String: Any]] {
                        for item in output {
                            if let content = item["content"] as? [[String: Any]] {
                                for cc in content {
                                    if let t = cc["text"] as? String { text += t }
                                }
                            }
                        }
                    } else if let content = json["content"] as? [[String: Any]] {
                        for cc in content {
                            if let t = cc["text"] as? String { text += t }
                        }
                    }
                }
                if !text.isEmpty {
                    completion(.success(text))
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "(no data)"
                    completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                                userInfo: [NSLocalizedDescriptionKey: "解析失败: \(raw.prefix(200))"])))
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
    /// v2.9.20：思考记录（reasoning）。Responses API 返回的 reasoning 摘要，气泡内可展开。
    var thinking: String? = nil

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
    /// v2.9.34：请求过程可视化——当前第几轮（对齐老 MCP 的"正在请求模型（第 N/60 轮）"）
    @Published var requestRound = 0
    @Published var requestRounds = 60
    /// v2.9.34：正在执行的工具名（展示"正在执行工具 xxx…"）
    @Published var runningTool: String?

    // v2.9.87：网络恢复自动重试（"切后台回来网络中断"补偿）——
    // 网络类错误且当前确认为断网时，等 AppLifecycleMonitor 广播 networkRestored 后自动重发一次。
    private var retryObserver: NSObjectProtocol?
    private var retriedNetworkOnce = false
    /// v2.9.13：当前正在进行的 OpenAIClient（支持取消）
    private var currentClient: OpenAIClient?
    /// v2.9.53：当前流式输出的消息 ID（逐字显示时跟踪，完成后更新或清理）
    private var streamingMessageId: UUID?

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
        // v2.9.22：新会话清空工具会话授权（AI 需重新搜索/决定）
        ToolRegistry.shared.clearSessionApproval()
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

    /// v2.9.53：流式输出时更新已有消息的 content（逐字显示）
    func updateMessageContent(id: UUID, content: String) {
        guard let idx = selectedIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages[mi].content = content
        conversations[idx].updatedAt = Date()
    }

    /// v2.9.53：删除指定消息（流式输出被工具调用替换时清理）
    func removeMessage(id: UUID) {
        guard let idx = selectedIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.remove(at: mi)
    }

    /// v2.9.13：取消当前进行中的请求（ChatView 停止按钮）
    func cancelCurrent() {
        cancelNetworkRetry()
        currentClient?.cancel()
        currentClient = nil
        isLoading = false
        statusText = nil
        // v2.9.82：回收后台任务
        TaskNotify.shared.endBackground()
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

    func send(_ text: String, using config: ModelConfig, imageDataURLs: [String]? = nil,
              reasoningLevel: Int = 0, smartSearch: Bool = true) {
        // v2.9.97：记住最近使用的模型，顶栏/下次启动立即恢复
        ModelStore.shared.markUsed(config.id.uuidString)
        // v2.9.82：请求开始——首次要通知权限 + 开启后台任务延长
        TaskNotify.shared.requestPermissionIfNeeded()
        TaskNotify.shared.beginBackground()
        // v2.9.87：新一轮请求重置网络重试状态
        retriedNetworkOnce = false
        cancelNetworkRetry()
        var msg = ChatMessage(role: "user", content: text)
        if let imgs = imageDataURLs, !imgs.isEmpty {
            msg.imageDataURLs = imgs
        }
        appendToCurrent(msg)
        isLoading = true

        // v2.9.16：渐进式披露——初始只带白名单工具 + tool_search 元工具，
        // 模型搜索命中后按需注入其余工具，避免 80+ 工具全量进请求导致慢/超时
        var baseTools = config.apiProtocol == "Anthropic Messages" ? nil : ToolRegistry.shared.enabledOpenAIToolSchema()
        // v2.9.20：智能搜索开关真实生效——关闭时从工具集移除 web.search / knowledge.search / web.fetch
        if !smartSearch {
            let exclude = Set(["web.search", "knowledge.search", "web.fetch"])
            baseTools = baseTools?.filter { t in
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String {
                    return !exclude.contains(n)
                }
                return true
            }
        }
        runLoop(config: config, tools: baseTools, disclosed: [], depth: 0, reasoningLevel: reasoningLevel)
    }

    // MARK: - v2.9.87 网络恢复自动重试

    private func shouldRetryOnNetworkRestore(_ err: NSError) -> Bool {
        guard !retriedNetworkOnce, err.code != -999 else { return false }
        // 网络类错误码：断网/找不到主机/网络连接丢失/连接重置
        let networkCodes: Set<Int> = [-1009, -1003, -1005, -1004, -1001]
        let isNetworkError = err.domain == NSURLErrorDomain && networkCodes.contains(err.code)
        // 只对"当前确实断网"的情况等待重试（确认不是中转站问题）
        return isNetworkError && !AppLifecycleMonitor.shared.isNetworkAvailable
    }

    private func scheduleRetryAfterNetworkRestore(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int) {
        retriedNetworkOnce = true
        retryObserver = NotificationCenter.default.addObserver(
            forName: AppLifecycleMonitor.networkRestored,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let o = self.retryObserver {
                NotificationCenter.default.removeObserver(o)
                self.retryObserver = nil
            }
            self.statusText = "网络已恢复，自动重试…"
            self.isLoading = true
            self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
        }
    }

    private func cancelNetworkRetry() {
        if let o = retryObserver {
            NotificationCenter.default.removeObserver(o)
            retryObserver = nil
        }
    }

    private func runLoop(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int = 0) {
        // v2.9.25：不再限制工具调用轮次（用户可手动点「停止」）。
        // 仅保留 60 轮极端安全保险，正常流程永不触发，防止 AI 完全失控无限发请求。
        guard depth < 60 else {
            isLoading = false
            statusText = nil
            requestRound = 0
            runningTool = nil
            // v2.9.82：后台时通知
            TaskNotify.shared.endBackground()
            TaskNotify.shared.notifyIfBackground(title: "⏹ 任务已停止", body: "达到极端安全上限（60 轮），已停止。可点「停止」中断。")
            appendToCurrent(ChatMessage(role: "assistant", content: "已达到极端安全上限（60 轮），已停止。若 AI 仍在循环，请点输入框旁的「停止」按钮中断。", isError: true))
            return
        }
        // v2.9.34：请求过程可视化
        DispatchQueue.main.async {
            self.requestRound = depth + 1
            self.requestRounds = 60
            self.statusText = "已准备请求（正在整理会话与可用工具）"
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
        client.currentReasoningLevel = reasoningLevel
        currentClient = client
        var history = messagesForAPI(budget: config.contextTokens)
        // v2.9.74：系统指令（用户可在设置中切换默认，不可编辑）
        // ——优先级最高，高于开发者指令。替代 v2.9.34 写死的协作规范。
        history.insert(ChatMessage(role: "system", content: SystemPrompts.shared.selected.content), at: 0)
        // v2.9.19：默认开发者指令注入为 system 前缀（用户可自建并设为默认）
        if let devInstr = DeveloperInstructionStore.shared.defaultInjectionContent(), !devInstr.isEmpty {
            history.insert(ChatMessage(role: "system", content: "以下是开发者指令，请始终遵守：\n" + devInstr), at: 0)
        }

        client.send(messages: history, tools: effectiveTools, onStatus: { status in
            DispatchQueue.main.async {
                // v2.9.34：带轮次前缀，展示"正在请求模型（第 N/60 轮）…"
                if self.requestRound > 0 && !status.contains("第 ") {
                    self.statusText = "正在请求模型（第 \(self.requestRound)/\(self.requestRounds) 轮）· \(status)"
                } else {
                    self.statusText = status
                }
            }
        }, onDelta: { delta in
            // v2.9.53：流式逐字显示
            DispatchQueue.main.async {
                if let sid = self.streamingMessageId {
                    // 追加到已有流式消息
                    guard let idx = self.selectedIndex,
                          let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) else { return }
                    self.conversations[idx].messages[mi].content += delta
                } else {
                    // 第一次 delta：创建流式消息
                    let msg = ChatMessage(role: "assistant", content: delta)
                    self.streamingMessageId = msg.id
                    self.appendToCurrent(msg)
                }
            }
        }) { result in
            DispatchQueue.main.async {
                self.statusText = nil
                switch result {
                case .success(.text(let text, let thinking)):
                    self.isLoading = false
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    // v2.9.82：完成通知（后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "✅ AI 已回复", body: String(text.prefix(60)))
                    if let sid = self.streamingMessageId {
                        // 流式已显示，更新最终文本 + thinking
                        self.updateMessageContent(id: sid, content: text)
                        if let idx = self.selectedIndex,
                           let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }),
                           let th = thinking, !th.isEmpty {
                            self.conversations[idx].messages[mi].thinking = th
                        }
                        self.streamingMessageId = nil
                    } else {
                        var am = ChatMessage(role: "assistant", content: text)
                        if let th = thinking, !th.isEmpty { am.thinking = th }
                        self.appendToCurrent(am)
                    }
                case .success(.toolCalls(let calls)):
                    // 工具调用：删除流式文本消息（如果有），然后显示工具调用
                    if let sid = self.streamingMessageId {
                        self.removeMessage(id: sid)
                        self.streamingMessageId = nil
                    }
                    let summary = calls.map { "调用工具 \($0.name)" }.joined(separator: "\n")
                    self.appendToCurrent(ChatMessage(role: "assistant", content: summary, toolCalls: calls))
                    // v2.9.31：递归处理一批工具调用（后台执行，无授权弹窗）
                    self.processToolCalls(calls, index: 0, toolMessages: [], newlyDisclosed: [],
                                          config: config, tools: tools, disclosed: disclosed, depth: depth,
                                          reasoningLevel: reasoningLevel)
                case .failure(let error):
                    self.isLoading = false
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    // v2.9.13：用户主动取消（-999）不追加错误气泡
                    let nsErr = error as NSError
                    if nsErr.code == -999 {
                        self.statusText = nil
                        self.streamingMessageId = nil
                        // v2.9.82：取消也算结束，回收后台任务但不通知
                        TaskNotify.shared.endBackground()
                        return
                    }
                    // v2.9.87：网络类错误 + 当前确认断网 → 等网络恢复自动重试一次
                    if self.shouldRetryOnNetworkRestore(nsErr) {
                        self.statusText = "网络不可用，等待恢复后自动重试…"
                        self.scheduleRetryAfterNetworkRestore(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
                        return
                    }
                    // v2.9.82：失败通知（后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "⚠️ 任务出错", body: String(error.localizedDescription.prefix(60)))
                    // 流式失败时保留已输出的部分文本，追加错误提示
                    if self.streamingMessageId != nil {
                        self.streamingMessageId = nil
                    }
                    self.appendToCurrent(ChatMessage(role: "assistant", content: "⚠️ \(error.localizedDescription)", isError: true))
                }
            }
        }
    }

    /// v2.9.31：递归处理一批工具调用。工具在后台线程执行（避免耗时操作阻塞主线程），
    /// 结果经 handleDispatchResult 回主线程继续。
    private func processToolCalls(_ calls: [ToolCall],
                                  index: Int,
                                  toolMessages: [ChatMessage],
                                  newlyDisclosed: [String],
                                  config: ModelConfig,
                                  tools: [[String: Any]]?,
                                  disclosed: [String],
                                  depth: Int,
                                  reasoningLevel: Int) {
        if index >= calls.count {
            for tm in toolMessages { self.appendToCurrent(tm) }
            let merged = Array(Set(disclosed + newlyDisclosed))
            self.runLoop(config: config, tools: tools, disclosed: merged, depth: depth + 1, reasoningLevel: reasoningLevel)
            return
        }
        let call = calls[index]
        let params = Self.parseArgs(call.arguments)
        // v2.9.34：展示"正在执行工具 xxx…"
        self.runningTool = call.name
        do {
            // v2.9.29：工具执行放后台线程，避免注入/文件操作等耗时调用阻塞主线程
            // （授权恢复后执行注入导致一直转圈 + 聊天框/输入框无响应）。
            // dispatch 在后台执行，结果/授权/错误统一回主线程继续递归。
            DispatchQueue.global().async {
                let result: Result<[String: Any], Error>
                do { result = .success(try ToolRegistry.shared.dispatch(name: call.name, params: params)) }
                catch { result = .failure(error) }
                DispatchQueue.main.async {
                    self.runningTool = nil
                    self.handleDispatchResult(result, call: call, calls: calls, index: index,
                                              toolMessages: toolMessages, newlyDisclosed: newlyDisclosed,
                                              config: config, tools: tools,
                                              disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
                }
            }
        }
    }

    /// v2.9.29：在主线程处理一次工具执行结果，然后继续递归调用链
    /// v2.9.31：去掉授权弹窗分支（工具搜索即自动授权，无需暂停等待用户选择）。
    private func handleDispatchResult(_ result: Result<[String: Any], Error>,
                                      call: ToolCall, calls: [ToolCall], index: Int,
                                      toolMessages: [ChatMessage], newlyDisclosed: [String],
                                      config: ModelConfig, tools: [[String: Any]]?,
                                      disclosed: [String], depth: Int, reasoningLevel: Int) {
        switch result {
        case .success(let r):
            let rawContent = Self.jsonString(r)
            // v2.9.49：工具结果截断（>8000字符），防止单条工具结果（如 browser.snapshot / injection.list）
            // 撑爆上下文导致后续请求巨慢。截断后加提示，模型可调用带分页/过滤参数的工具获取完整数据。
            let content: String
            if rawContent.count > 8000 {
                content = rawContent.prefix(8000) + "\n... [工具结果已截断，共 \(rawContent.count) 字符。如需完整数据，请调用该工具时使用 limit/filter/query 等参数缩小范围。]"
            } else {
                content = rawContent
            }
            var next = toolMessages
            next.append(ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name))
            var nextDisclosed = newlyDisclosed
            // v2.9.16：tool_search 命中后，把搜到的工具名加入待披露集合
            // v2.9.27：修复披露 bug——ToolSearchTool 返回 [[String: String]]，
            // 原 as? [[String: Any]] 因 Dictionary Value 泛型不同永远失败，
            // 导致搜到的工具下一轮从不注入 schema（AI 永远拿不到接口）。
            if call.name == "tool_search" {
                if let arr = r["tools"] as? [[String: String]] {
                    for item in arr {
                        if let n = item["name"], !n.isEmpty {
                            nextDisclosed.append(n)
                        }
                    }
                } else if let arr = r["tools"] as? [[String: Any]] {
                    for item in arr {
                        if let n = item["name"] as? String, !n.isEmpty {
                            nextDisclosed.append(n)
                        }
                    }
                }
            }
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: nextDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
        case .failure(let err as MCPError):
            var next = toolMessages
            next.append(ChatMessage(role: "tool", content: "error: \(err)", isError: true, toolCallId: call.id, toolName: call.name))
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
        case .failure(let err):
            var next = toolMessages
            next.append(ChatMessage(role: "tool", content: "error: \(err)", isError: true, toolCallId: call.id, toolName: call.name))
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
        }
    }

    private func messagesForAPI(budget: Int) -> [ChatMessage] {
        let all = currentMessages.filter { !$0.isError }
        guard !all.isEmpty else { return all }
        // v2.9.87：预算预留 30% 给 tools schema + 系统/开发者指令 + 请求开销。
        // 之前只按消息估算，tools（可能几十 KB JSON）+ 两条 system 前缀没算，
        // 长会话+多工具时实际请求体远超预算 → 中转处理慢（"一直请求中"）。
        let theBudget = max(Int(Double(budget) * 0.7), 2000)
        // 估算总 token；低于预算直接返回（短会话）
        let total = all.reduce(0) { $0 + Self.estimateTokens($1) }
        if total <= theBudget { return all }
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
            if used + t > theBudget { break }
            kept.append(m)
            used += t
        }
        var result = kept + suffix
        // 清理孤立 tool 消息：裁剪可能导致 assistant(tool_calls) 被裁、其 tool 结果残留
        result = Self.sanitizeToolSequence(result)
        // 插入截断提示（v2.9.88：本地生成话题摘要，而非简单丢弃 —— 不用额外请求，
        // 从被裁消息里提取用户提问/工具名作为"旧会话记忆"，AI 仍能感知上下文主题）
        let dropped = all.count - result.count
        if dropped > 0 {
            let droppedMsgs = Array(all.prefix(all.count - result.count))
            var topics: [String] = []
            var toolNames: Set<String> = []
            var idx = 0
            for m in droppedMsgs {
                idx += 1
                if m.role == "tool" { continue }
                if let calls = m.toolCalls, !calls.isEmpty {
                    for c in calls {
                        if !c.name.isEmpty {
                            toolNames.insert(c.name)
                        }
                    }
                    if topics.count < 8, idx % 4 == 0 { topics.append("工具调用") }
                    continue
                }
                if m.role == "user" || m.role == "assistant" {
                    let text = m.content.replacingOccurrences(of: "\n", with: " ")
                    if !text.isEmpty, topics.count < 8 {
                        topics.append(String(text.prefix(24)))
                    }
                }
            }
            var summaryParts: [String] = ["已省略最早 \(dropped) 条历史消息"]
            if !topics.isEmpty {
                summaryParts.append("话题: " + topics.prefix(6).joined(separator: " / "))
            }
            if !toolNames.isEmpty {
                summaryParts.append("涉及工具: " + toolNames.sorted().prefix(10).joined(separator: "、"))
            }
            summaryParts.append("如需旧细节，请直接提问，AI 会重新执行相关工具获取。")
            let hint = ChatMessage(role: "system", content: "[系统] " + summaryParts.joined(separator: "。"))
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
        // v2.9.87：CJK 1.5→2.0 保守估算（中文实际约 1.5~2 token/字），
        // 低估会让请求体超预算 → 中转处理慢。
        t += Int(Double(cjk) * 2.0) + ascii / 3
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
            // v2.9.107：原子写前备份轮换（保留最近 2 份，防会话数据损坏丢失）
            let ud = UserDefaults.standard
            if let cur = ud.data(forKey: key) {
                if let old = ud.data(forKey: key + ".bak.1") { ud.set(old, forKey: key + ".bak.2") }
                ud.set(cur, forKey: key + ".bak.1")
            }
            ud.set(data, forKey: key)
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
        // v2.9.107：主数据损坏时从备份恢复
        for i in 1...2 {
            if let bak = UserDefaults.standard.data(forKey: key + ".bak.\(i)"),
               let decoded = try? JSONDecoder().decode([ChatConversation].self, from: bak),
               !decoded.isEmpty {
                conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
                selectedId = conversations.first?.id
                return
            }
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

// MARK: - 熔断器（v2.9.107，对齐 cc-switch circuit_breaker 三态机）

enum CircuitState: String {
    case closed = "closed", open = "open", halfOpen = "half_open"
    var label: String {
        switch self {
        case .closed: return "正常"
        case .open: return "已熔断"
        case .halfOpen: return "探测中"
        }
    }
}

final class CircuitBreaker {
    private let lock = NSLock()
    private var state: CircuitState = .closed
    private var consecutiveFailures = 0
    private var consecutiveSuccesses = 0
    private var totalRequests = 0
    private var failedRequests = 0
    private var lastOpenedAt: Date?
    private var halfOpenRequests = 0

    var failureThreshold = 4          // 连续失败阈值 → Open
    var successThreshold = 2          // HalfOpen 成功次数 → Closed
    var timeoutSeconds: TimeInterval = 60  // Open 后多久尝试 HalfOpen
    var errorRateThreshold = 0.6      // 错误率阈值 → Open
    var minRequests = 10              // 计算错误率前最少请求数

    let name: String
    init(name: String) { self.name = name }

    var stateInfo: (state: CircuitState, failures: Int, total: Int, failRate: Double) {
        lock.lock(); defer { lock.unlock() }
        let rate = totalRequests > 0 ? Double(failedRequests) / Double(totalRequests) : 0
        return (state, consecutiveFailures, totalRequests, rate)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        state = .closed
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        totalRequests = 0
        failedRequests = 0
        halfOpenRequests = 0
        lastOpenedAt = nil
    }

    /// 路由可用性判断（不占 HalfOpen 探测名额）
    func isAvailable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed, .halfOpen:
            return true
        case .open:
            if let opened = lastOpenedAt, Date().timeIntervalSince(opened) >= timeoutSeconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                halfOpenRequests = 0
                return true
            }
            return false
        }
    }

    /// 请求前调用：是否放行（HalfOpen 限流 1 个探测请求）
    func allowRequest() -> (allowed: Bool, usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed:
            return (true, false)
        case .open:
            if let opened = lastOpenedAt, Date().timeIntervalSince(opened) >= timeoutSeconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                halfOpenRequests = 0
            } else {
                return (false, false)
            }
            if halfOpenRequests < 1 {
                halfOpenRequests += 1
                return (true, true)
            }
            return (false, false)
        case .halfOpen:
            if halfOpenRequests < 1 {
                halfOpenRequests += 1
                return (true, true)
            }
            return (false, false)
        }
    }

    func recordSuccess(usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if usedHalfOpenPermit, halfOpenRequests > 0 { halfOpenRequests -= 1 }
        consecutiveFailures = 0
        totalRequests += 1
        if state == .halfOpen {
            consecutiveSuccesses += 1
            if consecutiveSuccesses >= successThreshold {
                state = .closed
                consecutiveSuccesses = 0
                totalRequests = 0
                failedRequests = 0
                halfOpenRequests = 0
            }
        }
    }

    func recordFailure(usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if usedHalfOpenPermit, halfOpenRequests > 0 { halfOpenRequests -= 1 }
        consecutiveFailures += 1
        consecutiveSuccesses = 0
        totalRequests += 1
        failedRequests += 1
        switch state {
        case .halfOpen:
            state = .open
            lastOpenedAt = Date()
            consecutiveFailures = 0
        case .closed:
            if consecutiveFailures >= failureThreshold {
                state = .open
                lastOpenedAt = Date()
                consecutiveFailures = 0
            } else if totalRequests >= minRequests {
                let rate = Double(failedRequests) / Double(totalRequests)
                if rate >= errorRateThreshold {
                    state = .open
                    lastOpenedAt = Date()
                    consecutiveFailures = 0
                }
            }
        case .open:
            break
        }
    }
}
