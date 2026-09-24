import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

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
    /// v2.9.11：输入上下文预算 (token 估算）。发送前按预算自动裁剪最旧消息，
    /// 避免长会话请求体无限增长导致"一直请求中"。
    var contextTokens: Int = 16000
    /// v2.8.4：中转站兼容级别 (由 OpenAIClient 自适应降级时写入并持久化）
    /// 0=完整载荷 1=互换token参数名 2=去掉tool_choice 3=去掉tools纯对话 4=最小载荷
    var compatLevel: Int = 0
    /// v2.9.107：分组名 (供应商分组管理，对齐 cc-switch provider groups）
    var group: String = "默认"
    /// v3.1.1：是否支持视觉 (VLM），自动根据模型名判断
    var supportsVision: Bool {
        let m = model.lowercased()
        // 明确支持视觉的模型
        if m.contains("gpt-4o") || m.contains("gpt-4-vision") || m.contains("gpt-4v") { return true }
        if m.contains("claude-3") || m.contains("claude 3") { return true }
        if m.contains("gemini") { return true }
        if m.contains("qwen-vl") || m.contains("qwen2-vl") { return true }
        if m.contains("glm-4v") || m.contains("glm4v") { return true }
        if m.contains("vision") || m.contains("vl-") { return true }
        // 明确不支持的
        if m.contains("deepseek") { return false }
        if m.contains("gpt-3.5") || m.contains("gpt-35") { return false }
        // 默认：不支持 (保守策略，避免 API 报错）
        return false
    }

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
        // v2.9.2：OpenAI Completions (旧版文本补全）已移除，旧配置迁移到 Chat Completions
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

    /// 推理系列模型 (GPT-5.x / o1 / o3 / o4）不接受 temperature 参数，
    /// 中转站会返回 "Invalid request parameter"。
    var sendsTemperature: Bool { !isReasoningModel && !model.lowercased().contains("reasoning") }

    /// v2.8.5：是否推理系列模型 (GPT-5.x / o1 / o3 / o4）。
    /// 这类模型默认 reasoning_effort=medium，回复前会长时间思考 (聊天转圈半天的主因），
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
    private let key = "trollmcp2.model_configs"    // v2.9.97：记住最近一次使用的模型，顶栏立即显示用户上次用的配置，不再回退到第一个 (旧 gpt4o）
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
            // v2.9.107：主数据损坏时从备份restored (最多试 4 份）
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

    /// v2.9.107：原子写前备份轮换 (保留最近 4 份）
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

    // MARK: v2.9.107 —— 熔断器注册表 (运行时，不持久化；对齐 cc-switch circuit_breaker）

    private(set) var breakers: [UUID: CircuitBreaker] = [:]
    // v2.9.150：熔断器字典锁——ModelRow 渲染(主线程)与 AI 请求回调(后台线程)
    // 并发调 breaker(for:) 写同一字典 → 字典并发修改 SIGSEGV ("模型 API 页闪退"根因）
    private let breakerLock = NSLock()

    func breaker(for id: UUID) -> CircuitBreaker {
        breakerLock.lock()
        defer { breakerLock.unlock() }
        if let b = breakers[id] { return b }
        let b = CircuitBreaker(name: configs.first { $0.id == id }?.name ?? "model")
        breakers[id] = b
        return b
    }

    // MARK: v2.9.107 —— 配置导入 / 导出 (对齐 cc-switch import/export）

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

    /// v2.9.126：深链导入专用——同 baseURL+model 去重 (重复导入不再堆积配置）
    func importFromDeepLink(_ config: ModelConfig) -> Bool {
        let dup = configs.contains { $0.baseURL == config.baseURL && $0.model == config.model }
        guard !dup else { return false }
        add(config)
        markUsed(config.id.uuidString)
        return true
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
                    completion(.failure("parse failed: \(raw.prefix(200))"))
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
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        // v2.8.4：测试连接使用最小载荷 (仅 model + messages）。
        // 旧版发送 max_completion_tokens=8，推理模型 (gpt-5.x 默认 medium 推理）
        // 的推理 token 预算远超 8，会直接报参数错误，导致误判为连接failed。
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
                        completion(.success("连接OK (HTTP \(http.statusCode))"))
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


    // v2.9.100：通用轻量 chat 调用 (AI 分析引擎等内部工具用）。
    // 按 apiProtocol 自动选端点 (chat/completions / responses / messages），不触发工具循环。
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
        setHTTPMethod("POST", on: &request)
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
                                                userInfo: [NSLocalizedDescriptionKey: "no response数据"])))
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
                                                userInfo: [NSLocalizedDescriptionKey: "parse failed: \(raw.prefix(200))"])))
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
            // 空/未知鉴权方式但填了 key 时，默认按 Bearer 发送 (兼容旧配置或 UI 异常）
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
    /// v3.1.26：工具调用参数摘要 (tool 消息专用），UI 里用特殊颜色显示
    var toolArgs: String? = nil
    /// v3.3.4：工具执行耗时（秒），UI 气泡显示 (如 0.3s）
    var toolDuration: Double? = nil
    /// v2.9.9：多模态附件。存 data URL (如 "data:image/jpeg;base64,..."）。
    /// 发送时若非空，OpenAIClient 把 content 序列化为多模态数组。
    var imageDataURLs: [String]? = nil
    /// v2.9.20：思考记录 (reasoning）。Responses API 返回的 reasoning 摘要，气泡内可展开。
    var thinking: String? = nil
    /// v2.9.127：执行轨迹 (对齐豆包工作任务/Codex turn 流）——AI 本次回复的
    /// 思考→工具调用→工具结果 全过程，随消息持久化，可展开回看。
    var trail: [TrailStep]? = nil

    var isTool: Bool { role == "tool" }
}

/// v2.9.127：执行轨迹单步 (思考/工具调用/工具结果/备注）
struct TrailStep: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: Kind
    var name: String
    var status: Status
    var detail: String
    var ts: Date = Date()

    enum Kind: String, Codable { case think, tool, result, note }
    enum Status: String, Codable { case running, success, failed }

    static func running(_ kind: Kind, _ name: String, detail: String = "") -> TrailStep {
        TrailStep(kind: kind, name: name, status: .running, detail: detail)
    }
    static func done(_ kind: Kind, _ name: String, detail: String = "", ok: Bool = true) -> TrailStep {
        TrailStep(kind: kind, name: name, status: ok ? .success : .failed, detail: detail)
    }
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
    /// v2.8.5：当前请求的实时状态文案 (等待响应/降级重试中），展示在输入指示器旁
    @Published var statusText: String?
    /// v2.9.34：请求过程可视化——当前第几轮 (对齐老 MCP 的"正在请求模型 (第 N/60 轮）"）
    @Published var requestRound = 0
    @Published var requestRounds = 60
    /// v2.9.34：正在执行的工具名 (展示"正在执行工具 xxx…"）
    @Published var runningTool: String?
    /// v2.9.127：执行轨迹 (实时）——当前请求的 思考→工具调用→工具结果 步骤流，
    /// 请求结束时随最后一条 assistant 消息持久化 (message.trail）。
    @Published var liveTrail: [TrailStep] = []

    // v3.0.3：保存当前请求的思考内容 (onThinking 流式累加），
    // toolCalls 时传到 tool 消息，前端在 toolBubble 顶部显示
    private var thinkBuffer: String = ""

    // v2.9.87：网络恢复自动重试 ("切后台回来网络中断"补偿）——
    // 网络类错误且当前确认为断网时，等 AppLifecycleMonitor 广播 networkRestored 后自动重发一次。
    private var retryObserver: NSObjectProtocol?
    private var retriedNetworkOnce = false
    /// v2.9.13：当前正在进行的 OpenAIClient (支持取消）
    private var currentClient: OpenAIClient?
    /// v2.9.53：当前流式输出的消息 ID (逐字显示时跟踪，done后更新或清理）
    /// v3.4.5：改为 internal（ChatView 用它标记打字机效果的消息）
    var streamingMessageId: UUID?
    /// v3.4.9：本轮刚"生成完成"的 assistant 消息 ID（工具解说/整段到达的回复）。
    /// ChatView 用它给这些消息开打字机——它们 isStreaming=false 且内容在出现前已定好，
    /// 只能靠"本轮刚产出"这一信号触发逐字显示。请求整体结束后清空。
    var liveProducedID: UUID?
    /// v3.1.70：活动请求绑定的会话 ID——请求由哪个会话发起就写回哪个会话。
    /// 修复"请求进行中切换会话，AI 输出错位/写错会话" (用户实测：老会话未暂停，切换新会话后输出仍乱）。
    private var activeConvId: UUID?

    private let key = "trollmcp2.conversations"

    init() { load() }

    var selectedIndex: Int? {
        conversations.firstIndex { $0.id == selectedId }
    }

    /// v3.1.70：活动请求的会话 index (优先活动会话，兜底当前选中会话）
    private var activeConvIndex: Int? {
        if let id = activeConvId, let i = conversations.firstIndex(where: { $0.id == id }) {
            return i
        }
        return selectedIndex
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
        // v2.9.22：新会话清空工具会话授权 (AI 需重新搜索/决定）
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

    /// v3.1.70：写入活动请求的会话 (无活动请求时写入当前选中会话）
    func appendToCurrent(_ message: ChatMessage) {
        guard let idx = activeConvIndex else { return }
        var conv = conversations[idx]
        if conv.messages.isEmpty {
            conv.title = title(from: message.content)
        }
        conv.messages.append(message)
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
    }

    /// v3.1.70：更新活动请求会话内消息内容 (无活动请求时用当前选中会话）
    func updateMessageContent(id: UUID, content: String) {
        guard let idx = activeConvIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages[mi].content = content
        conversations[idx].updatedAt = Date()
    }

    /// v3.1.70：删除活动请求会话内的消息 (无活动请求时用当前选中会话）
    func removeMessage(id: UUID) {
        guard let idx = activeConvIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.remove(at: mi)
    }

    /// v2.9.13：取消当前进行中的请求 (ChatView 停止按钮）
    func cancelCurrent() {
        cancelNetworkRetry()
        currentClient?.cancel()
        currentClient = nil
        isLoading = false
        statusText = nil
        // v2.9.82：回收后台任务
        TaskNotify.shared.endBackground()
        // v3.1.70：停止——解除活动会话绑定
        activeConvId = nil
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
        // v3.1.70：请求绑定到发起时的会话——中途切换会话，输出仍写回该会话 (修复输出错位）
        activeConvId = selectedId
        // v3.4.9：新请求开始，清掉上一轮的"刚产出"标记（避免旧消息被重新打字）
        liveProducedID = nil
        var msg = ChatMessage(role: "user", content: text)
        if let imgs = imageDataURLs, !imgs.isEmpty {
            msg.imageDataURLs = imgs
        }
        appendToCurrent(msg)
        isLoading = true

        // v3.1.66：全量加载所有工具 (tool_search 已删除，不再渐进式披露）
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
        // v3.1.66：全量加载，disclosed 机制已不再新增工具 (tool_search 已删），
        // 保留仅为兼容会话内已授权工具 schema 的持久注入。
        let preDisclosed = ToolRegistry.shared.approvedToolNames()
        runLoop(config: config, tools: baseTools, disclosed: preDisclosed, depth: 0, reasoningLevel: reasoningLevel)
    }

    // MARK: - v2.9.87 网络恢复自动重试

    private func shouldRetryOnNetworkRestore(_ err: NSError) -> Bool {
        guard !retriedNetworkOnce, err.code != -999 else { return false }
        // 网络类错误码：断网/找不到主机/网络连接丢失/连接重置
        let networkCodes: Set<Int> = [-1009, -1003, -1005, -1004, -1001]
        let isNetworkError = err.domain == NSURLErrorDomain && networkCodes.contains(err.code)
        // 只对"当前确实断网"的情况等待重试 (确认不是中转站问题）
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

    /// v2.9.127：新一轮请求开始——清空实时轨迹
    func beginTrail() {
        DispatchQueue.main.async {
            self.liveTrail = []
        }
    }

    /// v2.9.127：追加一条实时轨迹步骤
    func trailStep(_ step: TrailStep) {
        DispatchQueue.main.async {
            self.liveTrail.append(step)
        }
    }

    /// v2.9.127：实时思考——把流式 reasoning 增量逐段追加到轨迹的"正在思考"步骤
    ///  (没有该步骤就新建，打字机式逐句累积）
    func appendThinking(_ delta: String) {
        DispatchQueue.main.async {
            let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var trail = self.liveTrail
            if let idx = trail.lastIndex(where: { $0.kind == .think && $0.status == .running }) {
                var step = trail[idx]
                step.detail += delta
                trail[idx] = step
            } else {
                trail.append(TrailStep.running(.think, "正在思考", detail: delta))
            }
            self.liveTrail = trail
        }
    }

    /// v2.9.127：把实时轨迹持久化到最后一条 assistant 消息 (AI 回复done后调用）
    /// thinking 非空时把"已思考"插到轨迹最前 (对齐豆包流程第一步）。
    /// 收尾：残留 running 步骤统一标OK/failed (消息报错则标failed）。
    func attachTrail(to messageId: UUID?, thinking: String? = nil) {
        guard let sid = messageId, !liveTrail.isEmpty else { return }
        DispatchQueue.main.async {
            if let idx = self.activeConvIndex,
               let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) {
                var trail = self.liveTrail
                let isErr = self.conversations[idx].messages[mi].isError
                for i in 0..<trail.count where trail[i].status == .running {
                    var s = trail[i]
                    s.status = isErr ? .failed : .success
                    trail[i] = s
                }
                // 思考去重：实时流已产生 think 步骤则不重复插入
                if let th = thinking, !th.isEmpty, !trail.contains(where: { $0.kind == .think }) {
                    trail.insert(TrailStep.done(.think, "已思考", detail: String(th.prefix(300))), at: 0)
                }
                self.conversations[idx].messages[mi].trail = trail
                self.save()
            }
        }
    }

    private func runLoop(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int = 0) {
        // v2.9.25：不再限制工具调用轮次 (用户可手动点「停止」）。
        // 仅保留 60 轮极端安全保险，正常流程永不触发，防止 AI 完全失控无限发请求。
        guard depth < 60 else {
            isLoading = false
            statusText = nil
            requestRound = 0
            runningTool = nil
            // v2.9.82：后台时通知
            TaskNotify.shared.endBackground()
            TaskNotify.shared.notifyIfBackground(title: "⏹ 任务已停止", body: "达到极端安全上限 (60 轮)，已停止。可点「停止」中断。")
            let stopMsg = ChatMessage(role: "assistant", content: "已达到极端安全上限 (60 轮)，已停止。若 AI 仍在循环，请点输入框旁的「停止」按钮中断。", isError: true)
            self.appendToCurrent(stopMsg)
            self.liveTrail = []   // v2.9.127：停止分支先清空上轮残留轨迹再收尾
            self.trailStep(.done(.note, "任务停止", detail: "达到 60 轮上限", ok: false))
            self.attachTrail(to: stopMsg.id)
            return
        }
        // v2.9.34：请求过程可视化
        DispatchQueue.main.async {
            self.requestRound = depth + 1
            self.requestRounds = 60
            self.statusText = "已准备请求 (正在整理会话与可用工具)"
            self.liveTrail = []   // v2.9.127：新一轮清空实时轨迹
        }

        // 动态合并：白名单 schema + 已披露工具的 schema (去重）
        // v2.9.175：tools 为 nil (Anthropic 协议）时也走空数组合并——Anthropic 通道
        // 现在同样能拿到 coreTools + 已披露工具的 schema (OpenAIClient 已支持转换）。
        var effectiveTools = tools ?? []
        if !disclosed.isEmpty {
            var existing = Set<String>()
            for t in effectiveTools {
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String {
                    existing.insert(n)
                }
            }
            for name in disclosed {
                let apiName = name.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").inverted).joined(separator: "_")
                if existing.contains(apiName) { continue }
                if let schema = ToolRegistry.shared.openAISchema(for: name) {
                    effectiveTools.append(schema)
                    existing.insert(apiName)
                }
            }
        }

        let client = OpenAIClient(config)
        client.currentReasoningLevel = reasoningLevel
        currentClient = client
        var history = messagesForAPI(budget: config.contextTokens)
        // v2.9.138：模块化 system prompt 组装 (稳定前缀工程）——
        // 稳定块 (系统指令→开发者指令）在前、动态状态块 (设备/App/工作区/会话）在后，
        // 稳定前缀保持字节一致 → 官方 API 前缀缓存可直接matched (Anthropic/OpenAI）。
        history.insert(ChatMessage(role: "system", content: SystemPrompts.shared.selected.content), at: 0)
        if let devInstr = DeveloperInstructionStore.shared.defaultInjectionContent(), !devInstr.isEmpty {
            history.insert(ChatMessage(role: "system", content: "以下是开发者指令，请始终遵守：\n" + devInstr), at: 0)
        }
        // 动态状态块：最新信息放最后，不影响稳定前缀缓存
        history.insert(ChatMessage(role: "system", content: Self.dynamicStatePrompt()), at: 0)

        client.send(messages: history, tools: effectiveTools, onStatus: { status in
            DispatchQueue.main.async {
                // v2.9.34：带轮次前缀，展示"正在请求模型 (第 N/60 轮）…"
                if self.requestRound > 0 && !status.contains("第 ") {
                    self.statusText = "正在请求模型 (第 \(self.requestRound)/\(self.requestRounds) 轮)· \(status)"
                } else {
                    self.statusText = status
                }
            }
        }, onDelta: { delta in
            // v2.9.53：流式逐字显示
            DispatchQueue.main.async {
                if let sid = self.streamingMessageId {
                    // 追加到已有流式消息 (v3.1.70：按活动会话定位，切换会话不丢增量）
                    guard let idx = self.activeConvIndex,
                          let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) else { return }
                    self.conversations[idx].messages[mi].content += delta
                } else {
                    // 第一次 delta：创建流式消息
                    let msg = ChatMessage(role: "assistant", content: delta)
                    self.streamingMessageId = msg.id
                    self.liveProducedID = msg.id
                    self.appendToCurrent(msg)
                }
            }
        }, onThinking: { delta in
            // v2.9.127：实时思考流式——逐段追加到轨迹的"正在思考"步骤
            DispatchQueue.main.async {
                self.appendThinking(delta)
                // v3.0.3：同时保存到 thinkBuffer，供 toolCalls 时传到 tool 消息
                self.thinkBuffer += delta
                // v3.5.4：去掉 v3.5.1 的"reasoning 自动打进正文"——那会让思考内容混进主气泡、
                // 黄色思考气泡反而为空 (用户实测反馈)。思考只进轨迹 + thinkBuffer，
                // 最终由装配阶段写入 message.thinking(黄色气泡)；正文只放模型真正输出的文本。
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
                    self.thinkBuffer = "" // 重置缓冲区
                    // v2.9.138：自动会话记忆——一轮完整回复后落库 (供下会话 BM25 检索）
                    if let idx = self.activeConvIndex {
                        let msgs = self.conversations[idx].messages
                        let lastUser = msgs.last { $0.role == "user" }?.content ?? ""
                        let usedTools = msgs.compactMap { $0.toolName }
                        KnowledgeStore.shared.appendSessionMemory(
                            user: String(lastUser.prefix(80)),
                            reply: String(text.prefix(150)),
                            tools: Array(Set(usedTools)).sorted().suffix(8))
                    }
                    // v2.9.127：轨迹——回复done，附到消息持久化
                    self.trailStep(.done(.note, "AI 回复done", detail: String(text.prefix(80))))
                    // v2.9.82：done通知 (后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "✅ AI 已回复", body: String(text.prefix(60)))
                    if let sid = self.streamingMessageId {
                        // 流式已显示，更新最终文本 + thinking
                        self.updateMessageContent(id: sid, content: text)
                        if let idx = self.activeConvIndex,
                           let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }),
                           let th = thinking, !th.isEmpty {
                            self.conversations[idx].messages[mi].thinking = th
                        }
                        self.attachTrail(to: sid, thinking: thinking)
                        self.streamingMessageId = nil
                    } else {
                        var am = ChatMessage(role: "assistant", content: text)
                        if let th = thinking, !th.isEmpty { am.thinking = th }
                        self.appendToCurrent(am)
                        self.liveProducedID = am.id
                        self.attachTrail(to: am.id, thinking: thinking)
                    }
                    // v3.5.3：文本工具调用兜底——模型把 shell.exec("...")/shell_exec(...) 写成文本
                    // (而非结构化 tool_call) 时，系统本不执行、任务卡死。这里检测最终文本里的文本式
                    // shell 调用，提取命令并真正执行，继续 agent 循环（提示词兜底不住，代码兜底保证）。
                    self.runTextualShellIfNeeded(text: text, config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
                    // v3.1.70：整条请求链 (含工具递归）结束——解除活动会话绑定
                    self.activeConvId = nil
                case .success(.toolCalls(let calls, let thinking)):
                    // v3.5.2：系统级"一次一个工具"硬约束——模型一次批几个 toolCalls，
                    // 都裁成第一个：assistant 消息与执行只带这一个，执行完回模型让它看到
                    // 结果再决定下一步（一个接一个）。依赖调用必须等前一个结果才能决定下一步，
                    // 合批执行会让模型猜结果(违规)；提示词不可靠，代码兜底强制一次一个。
                    let calls = Array(calls.prefix(1))
                    // v3.1.72：思考(reasoning)与可见输出(content)分开存放——
                    // 旧逻辑把流式可见文本+思考合并成 thinkText 塞进 assistant.content，
                    // 又把同一 thinkText 塞进 tool 消息 thinking，导致 UI 上"回复内容"和
                    // "思考内容"显示一模一样、每轮工具调用重复一次 (用户实测反馈）。
                    var visibleText = ""
                    var reasoningText = self.thinkBuffer
                    if let th = thinking, !th.isEmpty {
                        reasoningText = reasoningText.isEmpty ? th : "\(reasoningText)\n\(th)"
                    }
                    // 先取流式可见文本（模型若已发解说则以其为准）
                    if let sid = self.streamingMessageId,
                       let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        visibleText = self.conversations[ci].messages[mi].content
                    }
                    // v3.4.7：边做边说——去掉"▶ 开始执行：工具名"机械合成。
                    // 用户明确要求：AI 要像直播一样自然说明这步在干嘛（参考 OpenMinis 逐步解说）。
                    // 推理模型常把解说写进 reasoning 而不发可见正文，这里把模型自己的思考(reasoning)
                    // 提升为可见解说；仅当 reasoning 也为空时才退化为工具名。
                    if visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !calls.isEmpty {
                        visibleText = Self.narrationText(reasoningText, calls: calls)
                    }
                    if let sid = self.streamingMessageId,
                       let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        // 保留流式可见文本作为回复内容，思考进 thinking 字段，toolCalls 挂上 (不删除重建）
                        // 若流式消息内容为空且已合成解说 → 写入合成解说
                        if self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.conversations[ci].messages[mi].content = visibleText
                        }
                        self.conversations[ci].messages[mi].toolCalls = calls
                        // v3.5.4：思考始终写入黄色气泡(message.thinking)，不再要求 content 为空——
                        // 此前 reasoning 被 v3.5.1 打进正文使 content 非空，导致 thinking 永不写入、黄泡为空。
                        // 与正文去重：部分中转把完整回答写进 reasoning_content，与 content 相同则不展示思考。
                        let cText = self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrim.isEmpty, !(cText == rTrim || rTrim.contains(cText) || cText.contains(rTrim)) {
                            self.conversations[ci].messages[mi].thinking = reasoningText
                        }
                    } else {
                        // 无流式消息 (流式未开始就被 toolCalls 打断）：新建 assistant 消息
                        var am = ChatMessage(role: "assistant", content: visibleText, toolCalls: calls)
                        let vTrim = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim2 = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrim2.isEmpty, !(vTrim == rTrim2 || rTrim2.contains(vTrim) || vTrim.contains(rTrim2)) {
                            am.thinking = reasoningText
                        }
                        self.appendToCurrent(am)
                        self.liveProducedID = am.id
                    }
                    self.thinkBuffer = "" // 重置缓冲区
                    self.streamingMessageId = nil
                    // v2.9.127：轨迹——AI 决定调用一批工具
                    self.trailStep(.done(.tool, "AI 选择调用 \(calls.count) 个工具",
                                         detail: calls.map { $0.name }.joined(separator: "、")))
                    // v2.9.31：递归处理一批工具调用 (后台执行，无授权弹窗）
                    // v3.1.72：thinkText 传可见文本 (工具调用前的说明），不再写入 tool 消息 thinking
                    self.processToolCalls(calls, index: 0, toolMessages: [], newlyDisclosed: [],
                                          config: config, tools: tools, disclosed: disclosed, depth: depth,
                                          reasoningLevel: reasoningLevel, thinkText: visibleText)
                case .failure(let error):
                    self.isLoading = false
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    self.thinkBuffer = "" // 重置缓冲区
                    self.liveProducedID = nil
                    // v2.9.13：用户主动取消 (-999）不追加错误气泡
                    let nsErr = error as NSError
                    if nsErr.code == -999 {
                        self.statusText = nil
                        self.streamingMessageId = nil
                        // v2.9.82：取消也算结束，回收后台任务但不通知
                        TaskNotify.shared.endBackground()
                        // v3.1.70：用户取消——解除活动会话绑定
                        self.activeConvId = nil
                        return
                    }
                    // v2.9.87：网络类错误 + 当前确认断网 → 等网络恢复自动重试一次
                    if self.shouldRetryOnNetworkRestore(nsErr) {
                        self.statusText = "网络不可用，等待恢复后自动重试…"
                        self.scheduleRetryAfterNetworkRestore(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
                        return
                    }
                    // v2.9.82：failed通知 (后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "⚠️ 任务出错", body: String(error.localizedDescription.prefix(60)))
                    // 流式failed时保留已输出的部分文本，追加错误提示
                    if self.streamingMessageId != nil {
                        self.streamingMessageId = nil
                    }
                    let errMsg = ChatMessage(role: "assistant", content: "⚠️ \(error.localizedDescription)", isError: true)
                    self.appendToCurrent(errMsg)
                    self.trailStep(.done(.note, "请求failed", detail: String(error.localizedDescription.prefix(200)), ok: false))
                    self.attachTrail(to: errMsg.id)
                    // v3.1.70：请求链结束——解除活动会话绑定
                    self.activeConvId = nil
                }
            }
        }
    }

    /// v2.9.127：轨迹摘要——取 JSON 里 ok/message/status 等关键字段，超长截断
    static func trailSummary(_ json: String) -> String {
        let trimmed = json.count > 300 ? String(json.prefix(300)) : json
        // 去掉换行压扁，便于步骤行内展示
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    /// v3.1.26：把参数 JSON 转成简短摘要 (比如 "url: https://xxx"）
    /// UI 里用特殊颜色显示，太长就截断
    static func summarizeArgs(_ argsString: String) -> String? {
        guard let data = argsString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 只取前 2 个参数，每个值截断到 50 字符
        let entries = json.prefix(2).map { key, value -> String in
            let val: String
            if let s = value as? String {
                val = s
            } else {
                val = "\(value)"
            }
            let truncated = val.count > 50 ? String(val.prefix(50)) + "..." : val
            return "\(key): \(truncated)"
        }
        return entries.joined(separator: ", ")
    }

    /// v3.4.7：把模型的思考(reasoning)整理成一句可见的"逐步解说"。推理模型的解说通常在思考里而非正文，
    /// 这里取其收尾结论段作为解说（工具调用前的最后一两句往往是"我先xxx"的说明）。
    private static func narrationText(_ thinking: String, calls: [ToolCall]) -> String {
        var t = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return calls.map { $0.name }.joined(separator: "、") }
        // 压缩多余换行
        t = t.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // 推理常是长段 COT，取收尾（工具调用前的最后结论句）作为解说，限制长度
        if t.count > 200 {
            t = String(t.suffix(200))
            if let dot = t.firstIndex(of: "\u{3002}") { t = String(t[t.index(after: dot)...]) } // 中文句号后开始
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// v2.9.31：递归处理一批工具调用。工具在后台线程执行 (避免耗时操作阻塞主线程），
    /// 结果经 handleDispatchResult 回主线程继续。
    /// v3.5.3：文本工具调用兜底——从最终文本里提取文本式 shell 调用命令（shell.exec("...") /
    /// shell_exec(command="...") 等）。模型把调用写成文本(而非结构化 tool_call)时系统不执行，
    /// 这里兜底提取出真实命令让 runTextualShellIfNeeded 真正执行。
    private static func extractTextualShellCommand(from text: String) -> String? {
        let patterns = [
            #"shell\.exec\s*\(\s*["']([^"']+?)["']\s*\)"#,          // shell.exec("cmd") / shell.exec('cmd')
            #"shell_exec\s*\(\s*command\s*[:=]\s*["']([^"']+?)["']"#, // shell_exec(command="cmd")
            #"shell_exec\s*\(\s*["']([^"']+?)["']\s*\)"#           // shell_exec("cmd")
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: []) else { continue }
            let ns = text as NSString
            if let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                let c = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { return c }
            }
        }
        return nil
    }

    /// v3.5.3：执行文本兜底提取出的 shell 命令，把结果作为 tool 消息上屏并继续 agent 循环，
    /// 让模型看到结果后能继续下一步（而非卡死在"写了文本没执行"）。
    private func runTextualShellIfNeeded(text: String, config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int) {
        guard let cmd = Self.extractTextualShellCommand(from: text) else { return }
        let cmdCopy = cmd
        DispatchQueue.global().async {
            let params: [String: Any] = ["command": cmdCopy]
            let result: Result<[String: Any], Error>
            do { result = .success(try ToolRegistry.shared.dispatch(name: "shell.exec", params: params)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                var tm = ChatMessage(role: "tool", content: "", toolCallId: UUID().uuidString, toolName: "shell.exec")
                switch result {
                case .success(let r):
                    let raw = Self.jsonString(r)
                    tm.content = raw.count > 8000 ? raw.prefix(8000) + "\n... [工具结果已截断, total \(raw.count) 字符]" : raw
                    tm.toolArgs = String("命令: \(cmdCopy.prefix(120))")
                    tm.toolDuration = 0.01
                case .failure(let e):
                    tm.content = "执行失败: \(e.localizedDescription)"
                    tm.isError = true
                    tm.toolArgs = String("命令: \(cmdCopy.prefix(120))")
                }
                self.appendToCurrent(tm)
                self.liveProducedID = tm.id
                // 继续 agent 循环，模型看到结果后可决定下一步
                self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel)
            }
        }
    }

    private func processToolCalls(_ calls: [ToolCall],
                                  index: Int,
                                  toolMessages: [ChatMessage],
                                  newlyDisclosed: [String],
                                  config: ModelConfig,
                                  tools: [[String: Any]]?,
                                  disclosed: [String],
                                  depth: Int,
                                  reasoningLevel: Int,
                                  thinkText: String = "") {
        // 一次一个硬约束已在 .toolCalls 源头把批次裁成 prefix(1)，这里 calls.count==1，
        // 执行完 index=1 >= calls.count 即回模型。
        if index >= calls.count {
            // v3.4.1：工具气泡已在 handleDispatchResult 逐条实时上屏（对齐 OpenMinis 逐步展示），
            // 不再攒批到最后统一追加 —— 边做边说更接近"直播"。
            let merged = Array(Set(disclosed + newlyDisclosed))
            self.runLoop(config: config, tools: tools, disclosed: merged, depth: depth + 1, reasoningLevel: reasoningLevel)
            return
        }
        let call = calls[index]
        let params = Self.parseArgs(call.arguments)
        // v2.9.34：展示"正在执行工具 xxx…"
        self.runningTool = call.name
        // v3.3.4：记录工具执行耗时（UI 气泡显示，对齐 OpenMinis 步骤耗时样式）
        let toolStart = CFAbsoluteTimeGetCurrent()
        // v2.9.127：轨迹——单工具开始执行 (参数序列化展示）
        self.trailStep(.running(.tool, call.name, detail: Self.jsonString(params)))
        do {
            // v2.9.29：工具执行放后台线程，避免注入/文件操作等耗时调用阻塞主线程
            //  (授权恢复后Run injection导致一直转圈 + 聊天框/输入框无响应）。
            // dispatch 在后台执行，结果/授权/错误统一回主线程继续递归。
            DispatchQueue.global().async {
                let result: Result<[String: Any], Error>
                do { result = .success(try ToolRegistry.shared.dispatch(name: call.name, params: params)) }
                catch { result = .failure(error) }
                let toolDuration = CFAbsoluteTimeGetCurrent() - toolStart
                DispatchQueue.main.async {
                    self.runningTool = nil
                    self.handleDispatchResult(result, call: call, calls: calls, index: index,
                                              toolMessages: toolMessages, newlyDisclosed: newlyDisclosed,
                                              config: config, tools: tools,
                                              disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                              thinkText: thinkText, toolDuration: toolDuration)
                }
            }
        }
    }

    /// v2.9.29：在主线程处理一次工具执行结果，然后继续递归调用链
    /// v2.9.31：去掉授权弹窗分支 (工具搜索即自动授权，无需暂停等待用户选择）。
    private func handleDispatchResult(_ result: Result<[String: Any], Error>,
                                      call: ToolCall, calls: [ToolCall], index: Int,
                                      toolMessages: [ChatMessage], newlyDisclosed: [String],
                                      config: ModelConfig, tools: [[String: Any]]?,
                                      disclosed: [String], depth: Int, reasoningLevel: Int,
                                      thinkText: String = "", toolDuration: Double = 0) {
        switch result {
        case .success(let r):
            let rawContent = Self.jsonString(r)
            // v2.9.49：工具结果截断 (>8000字符），防止单条工具结果 (如 browser.snapshot / injection.list）
            // 撑爆上下文导致后续请求巨慢。截断后加提示，模型可调用带分页/过滤参数的工具获取完整数据。
            let content: String
            if rawContent.count > 8000 {
                content = rawContent.prefix(8000) + "\n... [工具结果已截断，total \(rawContent.count) 字符。如需完整数据，请调用该工具时使用 limit/filter/query 等参数缩小范围。]"
            } else {
                content = rawContent
            }
            var next = toolMessages
            var toolMsg = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name)
            // v3.1.26：存参数摘要，UI 里用特殊颜色显示
            toolMsg.toolArgs = Self.summarizeArgs(call.arguments)
            // v3.3.4：耗时显示
            toolMsg.toolDuration = toolDuration
            // v3.1.72：不再写 toolMsg.thinking——思考已在 assistant 消息的 thinking 字段显示一次，
            // 旧逻辑把同一文本又塞进 tool 消息导致"回复内容和思考内容一模一样" (用户实测反馈）
            next.append(toolMsg)
            // v3.4.1：边做边说实时化——每完成一个工具立即上屏，不再攒批到最后统一显示
            self.appendToCurrent(toolMsg)
            // v2.9.127：轨迹——工具执行OK (结果摘要 200 字符，完整结果在 tool 消息里）
            self.trailStep(.done(.result, call.name,
                                 detail: Self.trailSummary(rawContent),
                                 ok: true))
            var nextDisclosed = newlyDisclosed
            // v3.1.66：tool_search 已删除，全量加载所有工具，无需披露机制。
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: nextDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText)
        case .failure(let err as MCPError):
            // v2.9.125：failed也输出结构化 JSON (对齐 CLI 返回协议），AI 可直接解析分类与下一步
            var next = toolMessages
            let failureBody: [String: Any]
            if case MCPError.classified(let m, let code, let reason, let nextStep) = err {
                failureBody = ["ok": false, "message": m,
                               "error": ["code": code, "reason": reason, "next_step": nextStep]]
            } else {
                failureBody = ["ok": false, "message": err.description]
            }
            let content = Self.jsonString(failureBody)
            var failMsg = ChatMessage(role: "tool", content: content, isError: true, toolCallId: call.id, toolName: call.name)
            // v3.1.72：不再写 failMsg.thinking (思考只在 assistant 消息显示一次，避免重复）
            // v3.3.4：耗时显示
            failMsg.toolDuration = toolDuration
            next.append(failMsg)
            // v3.4.1：边做边说实时化——失败也立即上屏
            self.appendToCurrent(failMsg)
            // v2.9.127：轨迹——工具执行failed (四分类错误摘要）
            self.trailStep(.done(.result, call.name,
                                 detail: Self.trailSummary(Self.jsonString(failureBody)),
                                 ok: false))
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText)
        case .failure(let err):
            var next = toolMessages
            // v3.0.77：智能错误诊断——AI 看到错误就知道为什么failed、下一步该做什么
            let errStr = err.localizedDescription.lowercased()
            var reason = "Tool execution failed"
            var nextStep = "Check the error message above. Try a different approach or tool."
            if errStr.contains("not found") || errStr.contains("no such file") {
                reason = "File or path does not exist"
                nextStep = "Check path with fs.tree or fs.find. If app container, verify bundle_id."
            } else if errStr.contains("refused") || errStr.contains("connection") || errStr.contains("unreachable") {
                reason = "Target app or service not reachable"
                nextStep = "Start the target app first, or check if injection is active (injection.status)."
            } else if errStr.contains("permission") || errStr.contains("denied") {
                reason = "Permission denied"
                nextStep = "Check tool permissions in settings, or use a different approach."
            } else if errStr.contains("required") || errStr.contains("invalid") {
                reason = "Missing or wrong parameter"
                nextStep = "Check tool parameters. Required params are marked (REQUIRED) in the tool description."
            } else if errStr.contains("timeout") {
                reason = "Operation timed out"
                nextStep = "Try again with longer timeout, or check if the app is responsive."
            }
            let errBody: [String: Any] = [
                "ok": false,
                "tool": call.name,
                "error": err.localizedDescription,
                "reason": reason,
                "next_step": nextStep
            ]
            var errMsg = ChatMessage(role: "tool", content: Self.jsonString(errBody),
                                    isError: true, toolCallId: call.id, toolName: call.name)
            // v3.1.72：不再写 errMsg.thinking (思考只在 assistant 消息显示一次，避免重复）
            next.append(errMsg)
            // v3.4.1：边做边说实时化——错误也立即上屏
            self.appendToCurrent(errMsg)
            self.trailStep(.done(.result, call.name,
                                 detail: "❌ \(err.localizedDescription.prefix(200))",
                                 ok: false))
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText)
        }
    }

    /// v2.9.138：动态会话状态块——设备/App/工作区/当前会话，injected system 最前
    ///  (位于稳定块之后，最新状态放最后）。让 AI 始终感知当前环境，不靠猜。
    private static func dynamicStatePrompt() -> String {
        var device = "iPhone"
        var os = ""
        #if canImport(UIKit)
        device = UIDevice.current.model
        os = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        #endif
        var appVer = ""
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { appVer = v }
        var parts = ["[当前环境] 设备: \(device)\(os.isEmpty ? "" : " · \(os)")"]
        if !appVer.isEmpty { parts.append("App: TrollAgent \(appVer)") }
        parts.append("工作区: \(Workspace.root.path)")
        if let idx = ConversationStore.shared.selectedIndex,
           idx < ConversationStore.shared.conversations.count {
            parts.append("当前会话: \(ConversationStore.shared.conversations[idx].title)")
        }
        // v3.1.5: 自动提取的关键信息 (App 名、bundle id、文件路径等）
        if let hint = AutoContextExtractor.shared.contextHint() {
            parts.append(hint)
        }
        return parts.joined(separator: " | ")
    }

    private func messagesForAPI(budget: Int) -> [ChatMessage] {
        var all = currentMessages.filter { !$0.isError }
        guard !all.isEmpty else { return all }
        // v2.9.138：工具结果修剪 (Claude Code Precision Forgetting Layer 1）——
        // 非最近 3 条 tool 消息、内容 > 300 字符的旧工具结果替换为紧凑占位符。
        // 零 LLM 成本回收上下文：AI 需要细节时可重新调用该工具。
        // v3.1.68：阈值 300 → 2000 (AI 实测"377 字符不该被截"属实，小结果不再替换）；
        // 替换时保留原内容前 500 字符 ("截空看不到主体"根因——占位符不再整条顶替，
        // 且后续预算裁剪/sanitize 删占位符时头部仍在，AI 不至于完全失去线索）。
        let toolIdx = all.enumerated().filter { $0.element.isTool }.map { $0.offset }
        let keepTool = Set(toolIdx.suffix(3))
        for (i, m) in all.enumerated() where m.isTool && !keepTool.contains(i) && m.content.count > 2000 {
            var nm = m
            let toolName = m.toolName ?? "tool"
            let head = String(m.content.prefix(500))
            nm.content = "[工具结果已修剪: \(toolName)，原\(m.content.count)字符，以下为头部]\n\(head)\n…如需完整结果请重新调用该工具并带 limit=20000 或 full=true"
            all[i] = nm
        }
        // v2.9.87：预算预留 30% 给 tools schema + 系统/开发者指令 + 请求开销。
        // 之前只按消息估算，tools (可能几十 KB JSON）+ 两条 system 前缀没算，
        // 长会话+多工具时实际请求体远超预算 → 中转处理慢 ("一直请求中"）。
        let theBudget = max(Int(Double(budget) * 0.7), 2000)
        // 估算总 token；低于预算直接返回 (短会话）
        let total = all.reduce(0) { $0 + Self.estimateTokens($1) }
        if total <= theBudget { return all }
        // 长会话：从旧到新裁剪，但始终保留最后 N 条核心消息
        let keepMin = 6
        var kept: [ChatMessage] = []
        // 先保留最新 keepMin 条 (含用户最新提问），其 token 计入预算
        let suffix = Array(all.suffix(keepMin))
        let prefix = Array(all.prefix(all.count - keepMin))
        var used = suffix.reduce(0) { $0 + Self.estimateTokens($1) }
        // 从旧到新累计到「预算 - suffix」内 (v2.9.16：suffix 计入预算，避免超发）
        for m in prefix {
            let t = Self.estimateTokens(m)
            if used + t > theBudget { break }
            kept.append(m)
            used += t
        }
        var result = kept + suffix
        // 清理孤立 tool 消息：裁剪可能导致 assistant(tool_calls) 被裁、其 tool 结果残留
        result = Self.sanitizeToolSequence(result)
        // 插入截断提示 (v2.9.88：本地生成话题摘要，而非简单丢弃 —— 不用额外请求，
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
        // v2.9.87：CJK 1.5→2.0 保守估算 (中文实际约 1.5~2 token/字），
        // 低估会让请求体超预算 → 中转处理慢。
        t += Int(Double(cjk) * 2.0) + ascii / 3
        t += (m.imageDataURLs?.count ?? 0) * 600   // 每张图约 600 token (低分辨率近似）
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

    // v2.9.171：工具结果序列化去掉 prettyPrinted → 紧凑 JSON (无缩进空格）。
    private static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func sortAndSave() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    private func title(from text: String) -> String {
        // v2.9.293：剔除附件描述，避免标题变成 "[📎 文件：全局加速+...2.deb]已保存到 /var/..."
        // 用正则兼容 [📎文件：/ [📎 文件：/ 中文冒号/英文冒号 所有变体
        var clean = text
        func stripTag(_ pattern: String) {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let ns = clean as NSString
            let range = NSRange(location: 0, length: ns.length)
            clean = rx.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        stripTag("\\[📎\\s*文件\\s*[：:][^\\]]*\\]")
        stripTag("\\[📱\\s*应用\\s*[：:][^\\]]*\\]")
        // 去掉 "已保存到 <路径>，可用..." 路径描述
        if let r = clean.range(of: "已保存到 ") {
            clean = String(clean[..<r.lowerBound])
        }
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "📎 文件" }
        let line = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return String(line.prefix(30))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(conversations) {
            // v2.9.107：原子写前备份轮换 (保留最近 2 份，防会话数据损坏丢失）
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

// MARK: - 熔断器 (v2.9.107，对齐 cc-switch circuit_breaker 三态机）

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

    var failureThreshold = 4          // 连续failed阈值 → Open
    var successThreshold = 2          // HalfOpen OK次数 → Closed
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

    /// 路由可用性判断 (不占 HalfOpen 探测名额）
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

    /// 请求前调用：是否放行 (HalfOpen 限流 1 个探测请求）
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

// MARK: - v2.9.126 深链导入暂存 (对齐 cc-switch DeepLinkImportDialog）

/// AppDelegate 收到 trollagent://import?... 后暂存配置，发通知；SwiftUI 层弹确认页。
/// 确认才写入 ModelStore (防误导入），取消即丢弃。
final class PendingImport: ObservableObject {
    static let shared = PendingImport()
    static let didStageNotification = Notification.Name("trollagent.pendingImport.staged")

    @Published var staged: ModelConfig?

    private init() {}

    func stage(_ config: ModelConfig) {
        staged = config
        NotificationCenter.default.post(name: Self.didStageNotification, object: config)
    }

    func confirm() {
        guard let c = staged else { return }
        let ok = ModelStore.shared.importFromDeepLink(c)
        staged = nil
        // 通知 UI 显示结果 (导入OK/已存在重复）
        NotificationCenter.default.post(name: Self.didStageNotification,
                                        object: nil,
                                        userInfo: ["result": ok ? "imported" : "duplicate"])
    }

    func cancel() {
        staged = nil
    }
}
