import Foundation
import Combine

enum ChatResult {
    case text(String, thinking: String?)
    /// v3.5.15：toolCalls 增加 content——把模型在工具轮写的正文解说(content)透传出来。
    /// 此前只带 thinking，非流式 chat/completions 路径(parseChoice)会把模型写的解说直接丢掉
    /// (用户实测"解说还没有"的根因之一)；带出后在 runLoop 用作 visibleText 兜底。
    case toolCalls([ToolCall], thinking: String?, content: String?)
}

/// 网络调试日志 (最近 100 条，环形覆盖），用于排查中转站兼容性问题。
/// 界面上在「设置 → 关于 → 网络兼容日志」查看。
final class NetworkLog: ObservableObject {
    static let shared = NetworkLog()

    /// 最近一条兼容性日志 (供设置页副标题展示）
    static var lastCompatNote: String?

    @Published private(set) var entries: [String] = []

    func log(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(text)"
        print("[NetworkLog] \(line)")
        DispatchQueue.main.async {
            self.entries.insert(line, at: 0)
            if self.entries.count > 100 { self.entries.removeLast(self.entries.count - 100) }
        }
    }
}

/// 兼容 API 客户端 (OpenAI / DeepSeek / Anthropic / 任意兼容端点）。
///
/// v2.8.4：针对中转站 (new-api 系）"Invalid request parameter" 报错实现**自适应兼容降级**。
/// 不同中转站 / 不同模型对参数的支持差异极大 (部分不认 max_completion_tokens、
/// 部分不支持 tool_choice、部分模型族在 chat/completions 上拒绝 tools），
/// 与其猜测，不如让客户端自己逐级试探并记住可用级别：
///
/// | 级别 | 载荷 |
/// |------|------|
/// | 0 | 完整载荷 (tools + tool_choice + 推理模型参数适配） |
/// | 1 | 0 基础上互换 token key (max_completion_tokens ↔ max_tokens） |
/// | 2 | 1 基础上去掉 tool_choice |
/// | 3 | 1 基础上去掉 tools (纯对话；历史中的 tool 消息降级为普通文本） |
/// | 4 | 最小载荷 (仅 model + messages） |
///
/// OK后把可用级别持久化到 ModelConfig.compatLevel，下次直接从该级别发起。
final class OpenAIClient {
    let config: ModelConfig
    /// v2.9.0：级别 5 = Responses API + 工具
    private let maxLevel = 5
    /// v2.9.10：自定义 session——waitsForConnectivity 让切后台/网络抖动时不立即failed，
    /// 资源超时放宽到 5 分钟 (配合后台恢复后继续请求）。
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForResource = 300
        cfg.timeoutIntervalForRequest = 90
        return URLSession(configuration: cfg)
    }()
    /// v2.9.13：取消支持——置位标志 + 取消当前 in-flight 任务
    private var cancelled = false
    private weak var activeTask: URLSessionDataTask?
    /// v2.9.15：本轮请求起始时间 (用于耗时统计，写入网络兼容日志）
    private var requestStart = Date()
    /// v2.9.107：本轮是否占用 HalfOpen 探测名额 (熔断记录时释放）
    private var usedHalfOpenPermit = false
    /// v2.9.299：当前请求是否已因"模型非视觉"剥离图片 (防止无限重试）
    private var imagesStrippedForVLM = false
    /// v2.9.87：多级降级总预算——全链串行最坏 7 分钟+，用户感知"一直请求中"。
    /// v2.9.96：试探级 (L0-L4）超时已压到 25s，预算放宽到 220s 给 L5 流式留足时间。
    private var overallDeadline = Date.distantFuture
    private let overallBudget: TimeInterval = 220
    /// v2.9.20：本轮推理强度 (0=低 1=中 2=高），由 ChatView 传入并真实作用于请求。
    var currentReasoningLevel = 0  // v2.9.49：默认 low (medium/high 推理显著增加延迟，对标 Codex CLI 默认 low）

    init(_ config: ModelConfig) {
        self.config = config
    }

    // MARK: - 对外入口

    /// v2.9.13：取消当前请求 (ChatView 停止按钮调用）
    func cancel() {
        cancelled = true
        activeTask?.cancel()
    }

    func send(messages: [ChatMessage], tools: [[String: Any]]? = nil, onStatus: ((String) -> Void)? = nil, onDelta: ((String) -> Void)? = nil, onThinking: ((String) -> Void)? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        cancelled = false
        requestStart = Date()
        overallDeadline = Date().addingTimeInterval(overallBudget)
        // v2.9.107：熔断检查 (对齐 cc-switch circuit_breaker）——供应商连续failed过多时直接拒绝，
        // 不再傻等超时 (用户痛点"一直请求中"）
        let gate = ModelStore.shared.breaker(for: config.id).allowRequest()
        usedHalfOpenPermit = gate.usedHalfOpenPermit
        if !gate.allowed {
            let el = Int(Date().timeIntervalSince(requestStart) * 1000)
            NetworkLog.shared.log("\(config.name) 已熔断，请求被拒绝 (\(el)ms)")
            completion(.failure(NSError(domain: "OpenAIClient", code: -503,
                userInfo: [NSLocalizedDescriptionKey: "供应商「\(config.name)」已熔断 (连续failed过多，已暂停请求以免卡死)。可在模型管理页点击该模型重置，或约 60 秒后自动恢复探测。"])))
            return
        }
        UsageRecorder.shared.begin(messages: messages)
        // v2.9.0：级别 5 = Responses API + 工具调用 (Codex 走的端点，GPT-5.6 家族
        // 在 chat/completions 上无法用 function tools，但 /v1/responses 可以）
        // v2.9.299：VLM 错误图片剥离标志——遇到"模型不是视觉模型"时只剥离一次
        self.imagesStrippedForVLM = false
        var start = min(max(config.compatLevel, 0), maxLevel)
        // 历史被记忆为"纯对话"(L3/L4) 的旧配置，给一次恢复工具调用的机会：
        // 先试 L5 (Responses API + 工具），failed自动回落 L3。
        if start == 3 || start == 4 {
            NetworkLog.shared.log("\(config.name): 当前记忆级别为纯对话，先尝试 Responses API 恢复工具调用…")
            start = 5
        }
        // v3.5.11：带工具请求优先走 L5 (Responses API = Codex 同款端点)——对齐 Codex/Claude Code
        // "一次流式先思考后行动"。L5 原生流式 reasoning→function_call，才能让模型每步有解说/思考；
        // 一直钉在 L0 (chat/completions 完整载荷) 则模型工具轮常不发 reasoning/narration (用户实测）。
        // 若 L5 failed，降级链会回落带工具的 L2 (chat/completions) 或 L3 纯对话，不影响可用性。
        // 审计修正：只在 L0(默认未降级) 时强制试 L5；一旦降级到 L1/L2 被记住，就尊重记忆级别——
        // 否则每次工具请求都白试一次 L5 再回落 (浪费往返)。L3/L4 已由上面分支尝试 L5 恢复。
        let hasTools = tools != nil && !(tools?.isEmpty ?? true)
        if hasTools, config.apiProtocol != "OpenAI Responses", config.compatLevel == 0 {
            NetworkLog.shared.log("\(config.name): 带工具请求，优先尝试 L5 Responses API (Codex 同款端点)…")
            start = 5
        }
        if start > 0 {
            NetworkLog.shared.log("\(config.name): 使用已记忆的兼容级别 \(start) (\(levelName(start)))")
        } else {
            NetworkLog.shared.log("\(config.name): 发起请求 (级别 0 完整载荷)")
        }
        // v2.9.88：请求全链路耗时可视化 —— 在外层包一层 completion，
        // 无论OK/failed/降级多少次，最终只上报一次总耗时 (首字节→流式→工具调用全含在内）。
        // 先调用原 completion (内部会清 statusText），再补报耗时，让用户看到"done用了多久"。
        let wrappedCompletion: (Result<ChatResult, Error>) -> Void = { result in
            let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
            completion(result)
            switch result {
            case .success:
                let secs = String(format: "%.1f", Double(el) / 1000.0)
                NetworkLog.shared.log("\(self.config.name) 请求done (\(el)ms)")
                onStatus?("响应done · 总耗时 \(secs)s (含降级重试)")
                ModelStore.shared.breaker(for: self.config.id).recordSuccess(usedHalfOpenPermit: self.usedHalfOpenPermit)
                UsageRecorder.shared.end(config: self.config, ok: true, elapsedMs: el)
            case .failure(let e):
                NetworkLog.shared.log("\(self.config.name) 请求failed (\(el)ms): \(e.localizedDescription)")
                ModelStore.shared.breaker(for: self.config.id).recordFailure(usedHalfOpenPermit: self.usedHalfOpenPermit)
                UsageRecorder.shared.end(config: self.config, ok: false, elapsedMs: el, error: e.localizedDescription)
            }
        }
        attempt(level: start, isFirst: true, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: wrappedCompletion)
    }

    /// 降级顺序：L0→L1→L2→ (带 tools 时优先 L5 Responses API，保住工具调用）→L3→L4→结束
    /// 返回 > maxLevel 的哨兵值表示降级链走完，无下一级可试。
    private func nextLevel(after level: Int, hasTools: Bool, avoidL5: Bool = false) -> Int {
        if level == 2, hasTools, !avoidL5 { return 5 }
        if level == 5 { return 3 }
        if level >= 4 { return 6 }   // 哨兵：链尾，避免 L4→L5→L3 循环
        return level + 1
    }

    // MARK: - 逐级试探

    private func attempt(level: Int, isFirst: Bool, messages: [ChatMessage], tools: [[String: Any]]?, onStatus: ((String) -> Void)?, onDelta: ((String) -> Void)?, onThinking: ((String) -> Void)? = nil, avoidL5: Bool = false, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        // v2.9.87：总预算检查——降级链整体超时直接failed，不再无限串行等
        if Date() > overallDeadline {
            let el = Int(Date().timeIntervalSince(requestStart) * 1000)
            NetworkLog.shared.log("\(config.name) 多级降级总预算耗尽 (\(Int(overallBudget))s，\(el)ms)")
            completion(.failure(NSError(domain: "OpenAIClient", code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "请求超时：已按 6 个兼容级别逐级尝试仍无响应 (total \(Int(overallBudget)) 秒)。可能是中转站负载过高或模型名错误，请稍后重试或检查模型配置。"])))
            return
        }
        if config.apiProtocol == "Anthropic Messages" {
            performAnthropic(messages: messages, tools: tools, completion: completion)
            return
        }
        // v2.9.0：手动选择 Responses 协议，或降级链走到 L5
        // v2.9.53：L5 默认走流式 (SSE），逐字显示 + done后解析
        if level == 5 || config.apiProtocol == "OpenAI Responses" {
            // 手动选择协议时不回落；经降级链进入 (L5）failed后回落 L3 纯对话
            let viaLadder = level == 5 && config.apiProtocol != "OpenAI Responses"
            performResponsesStream(messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking) { [weak self] result in
                guard let self = self else { return }
                if case .failure(let err) = result, viaLadder {
                    let nsErr = err as NSError
                    // v2.9.297：空响应 (中转不支持 Responses API）→ 回落 L2 带工具 chat/completions 并跳过 L5，避免死循环
                    if nsErr.code == -3040 || nsErr.code == -3041 {
                        self.attempt(level: 2, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: true, completion: completion)
                        return
                    }
                    // 其他failed：回落到已验证可用的纯对话模式
                    self.attempt(level: 3, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: completion)
                    return
                }
                completion(result)
            }
            return
        }

        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = "/chat/completions"
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 baseURL"])))
            return
        }

        // v2.8.6：首次请求 45s；降级重试 30s。
        // 中转对完整载荷 (tools + reasoning_effort）处理极慢/卡死，尽早超时并降级。
        // v2.9.12：长会话请求体大，放宽超时——首次 90s / 降级重试 60s (配合 session 90s）
        // v2.9.96：试探级统一 25s——正常中转 5s 内响应，卡死就是永远卡死，
        // 25s 判定足够，把时间预算留给 L5 Responses 流式 (Codex 同款端点）。
        var request = URLRequest(url: url, timeoutInterval: 25)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        var body = buildBody(level: level, messages: messages, tools: tools)
        injectBodyAuth(into: &body)
        applyParamAliases(into: &body)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // 记录发送的载荷摘要 (不含 apiKey），便于排查
        NetworkLog.shared.log("\(config.name) L\(level) \(levelName(level)) → POST \(endpoint)，字段: \(body.keys.sorted().joined(separator: ","))")
        if isFirst {
            onStatus?("正在等待模型响应…")
        } else {
            onStatus?("请求被拒绝，正在尝试简化参数 (级别 \(level)/\(maxLevel))…")
        }

        let task = session.dataTask(with: request) { data, response, error in
            if self.cancelled {
                completion(.failure(NSError(domain: "OpenAIClient", code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "请求已取消"])))
                return
            }
            if let error = error {
                let err = error as NSError
                // v2.8.6：网络超时 (不是 408 HTTP 状态，而是 URLSession 的 -1001）
                // 也可能是中转对完整载荷处理太慢/卡死，降级到轻量载荷很可能OK。
                let isTimeout = (err.code == NSURLErrorTimedOut
                    || err.domain == NSURLErrorDomain && err.code == -1001
                    || error.localizedDescription.contains("超时")
                    || error.localizedDescription.localizedLowercase.contains("timed out"))
                if isTimeout {
                    let next = self.nextLevel(after: level, hasTools: tools != nil && !(tools?.isEmpty ?? true), avoidL5: avoidL5)
                    if next <= self.maxLevel {
                        let remain = max(0, Int(self.overallDeadline.timeIntervalSinceNow))
                        NetworkLog.shared.log("\(self.config.name) L\(level) 请求超时 → 自动降级到 L\(next) (\(self.levelName(next)))")
                        onStatus?("请求超时，正在尝试简化参数 (级别 \(next)/\(self.maxLevel))· 总预算剩余 \(remain)s…")
                        self.attempt(level: next, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                        return
                    }
                }
                // 其它网络错误 (断网等）降级无意义
                let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                NetworkLog.shared.log("\(self.config.name) L\(level) 网络错误 (\(el)ms): \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0

            // 部分中转站 HTTP 200 但 body 是 {"error": {...}}
            var errorPayload: String?
            if let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] {
                if let err = json["error"] as? [String: Any] {
                    errorPayload = (err["message"] as? String) ?? "\(err)"
                } else if let errStr = json["error"] as? String {
                    errorPayload = errStr
                }
            }

            // OK解析 choices
            if errorPayload == nil,
               let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first {
                if level != self.config.compatLevel {
                    let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                    NetworkLog.shared.log("\(self.config.name) 级别 \(level) (\(self.levelName(level)))请求OK (\(el)ms)，已记忆该级别")
                    NetworkLog.lastCompatNote = "模型「\(self.config.name)」当前兼容级别: \(level) (\(self.levelName(level)))"
                    self.persist(level: level)
                }
                completion(.success(self.parseChoice(firstChoice)))
                return
            }

            // failed：判断是否可通过降级重试挽救
            let retryable = self.isRetryable(status: status, errorPayload: errorPayload)
            let failMsg = errorPayload ?? raw
            let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
            NetworkLog.shared.log("\(self.config.name) L\(level) failed (HTTP \(status)，耗时 \(el)ms): \(String(failMsg.prefix(200)))")

            // v2.9.299：模型非视觉 (VLM）错误——剥离全部图片后同级别重试一次
            let lowerErr = (errorPayload ?? "").lowercased()
            let isVLMError = lowerErr.contains("not a vlm") || lowerErr.contains("vision language model") || lowerErr.contains("vlm")
            if isVLMError, !self.imagesStrippedForVLM, messages.contains(where: { !($0.imageDataURLs ?? []).isEmpty }) {
                self.imagesStrippedForVLM = true
                var stripped = messages
                for i in stripped.indices {
                    if !(stripped[i].imageDataURLs ?? []).isEmpty {
                        stripped[i].imageDataURLs = nil
                        stripped[i].content += "\n[📎 图片已自动移除：当前模型不支持看图 (非视觉模型)]"
                    }
                }
                NetworkLog.shared.log("\(self.config.name): 模型非视觉，剥离图片后重试 L\(level)")
                onStatus?("当前模型不支持看图，已自动移除图片重试…")
                self.attempt(level: level, isFirst: false, messages: stripped, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                return
            }

            if retryable {
                let next = self.nextLevel(after: level, hasTools: tools != nil && !(tools?.isEmpty ?? true), avoidL5: avoidL5)
                if next <= self.maxLevel {
                    NetworkLog.shared.log("\(self.config.name) 自动降级 → 级别 \(next) (\(self.levelName(next)))")
                    self.attempt(level: next, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                    return
                }
            }
            let hint = errorPayload != nil ? "" : "\n提示: 响应非标准 OpenAI 格式，请检查 baseURL 是否指向 /v1 兼容端点。"
            completion(.failure(NSError(domain: "OpenAIClient", code: status,
                userInfo: [NSLocalizedDescriptionKey: "请求被拒绝 (HTTP \(status)，已尝试到级别 \(level)·\(self.levelName(level)))\n\(String(failMsg.prefix(300)))\(hint)"])))
        }
        activeTask = task
        task.resume()
    }

    // MARK: - 载荷构建

    private func buildBody(level: Int, messages: [ChatMessage], tools: [[String: Any]]?) -> [String: Any] {
        // 级别 ≥3：去掉 tools 后，历史中的 tool / tool_calls 消息必须降级为普通文本，否则请求体本身非法
        let sanitized: [ChatMessage]
        if level >= 3 {
            sanitized = messages.filter { $0.role != "tool" }.map { m in
                var mm = m
                mm.toolCalls = nil
                return mm
            }
        } else {
            sanitized = messages
        }

        // OpenAI Chat Completions / Custom Endpoint
        if level >= 4 {
            return ["model": config.model, "messages": trimmedMessages(sanitized).map { messageDict($0) }]
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": trimmedMessages(sanitized).map { messageDict($0) },
            tokenKey(level: level): config.maxTokens
        ]
        if level < 3, config.sendsTemperature {
            body["temperature"] = config.temperature
        }
        // v2.9.20：推理强度由 UI 真实控制 (0低=low 1中=medium 2高=high）。
        // 低档仍比 none 有思考但显著提速；中档为默认。
        // 级别 4 (最小载荷）不带该字段——若中转连这个字段都不认，还有最后一级兜底。
        if config.isReasoningModel {
            body["reasoning_effort"] = reasoningEffortName()
            // v3.1.74：思考/回复语言跟随 App 设置 (设置 → 语言），不再硬编码中文
            // v3.1.33 曾强制简体中文思考；现在按 LanguageManager.shared.language 动态下发
            // v3.5.11：追加"先解说后执行"指令（对齐 Codex/Claude Code 一次流式先思考后行动）——
            // 要求模型在调用任何工具前，先在回复正文 content 里写一两句解说，再发 tool_calls。
            var instr = LanguageManager.shared.isZh
                ? "你的思考过程 (reasoning/thinking)请始终使用简体中文输出。最终回复也使用简体中文，除非用户明确要求其他语言。"
                : "Always think and reply in English unless the user explicitly asks for another language."
            instr += LanguageManager.shared.isZh
                ? "\n重要：在你调用任何工具之前，必须先在回复正文（content，不要放进 reasoning）里用一两句自然语言向用户说明你正要做什么、为什么。写完解说后再调用工具。"
                : "\nIMPORTANT: Before calling any tool, you MUST first write one or two sentences in the reply content (not in reasoning) explaining what you are about to do and why. Then call the tool."
            body["instructions"] = instr
        }
        if let tools = tools, !tools.isEmpty {
            if level < 3 {
                body["tools"] = tools
                if level < 2 {
                    body["tool_choice"] = "auto"
                }
            }
        }
        return body
    }

    /// 级别 0 用模型偏好的 key；级别 1 互换 (中转站可能只认其中一个）
    private func tokenKey(level: Int) -> String {
        let preferred = config.maxTokensKey
        if level == 1 { return preferred == "max_completion_tokens" ? "max_tokens" : "max_completion_tokens" }
        return preferred
    }

    /// v2.9.20：推理强度名。0=low 1=medium 2=high 3=none (完全不思考）
    private func reasoningEffortName() -> String {
        switch currentReasoningLevel {
        case 0: return "low"
        case 2: return "high"
        case 3: return "none"
        default: return "medium"
        }
    }

    private func levelName(_ level: Int) -> String {
        switch level {
        case 0: return "完整载荷"
        case 1: return "互换token参数名"
        case 2: return "去掉tool_choice"
        case 3: return "去掉tools纯对话"
        case 4: return "最小载荷"
        case 5: return "Responses API+工具"
        default: return "未知"
        }
    }

    /// 4xx 参数类错误可通过降级挽救；
    /// 5xx 网关/上游超时 (尤其 tools 过多导致 relay/gpt-5.6 超时或 500）降级到轻量载荷可能OK；
    /// 鉴权(401/402/403)、配额(429) 不降级。
    private func isRetryable(status: Int, errorPayload: String?) -> Bool {
        if status == 401 || status == 402 || status == 403 || status == 429 { return false }
        if status >= 400 && status < 500 { return true }
        // 502/503/504：网关错误 / 上游处理超时；500：terra 处理 tools 超限时报 server_error
        if status == 500 || status == 502 || status == 503 || status == 504 { return true }
        // HTTP 200 + error body (new-api 中转常见）：只有参数类错误才降级
        if let msg = errorPayload?.lowercased() {
            let keywords = ["invalid request parameter", "invalid_request", "unsupported parameter", "not supported",
                            "unknown parameter", "extra inputs", "参数", "invalid request"]
            return keywords.contains { msg.contains($0) }
        }
        return false
    }

    private func parseChoice(_ firstChoice: [String: Any]) -> ChatResult {
        if let message = firstChoice["message"] as? [String: Any] {
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                let calls: [ToolCall] = toolCalls.compactMap { tc in
                    guard let id = tc["id"] as? String,
                          let type = tc["type"] as? String, type == "function",
                          let fn = tc["function"] as? [String: Any],
                          let name = fn["name"] as? String,
                          let args = fn["arguments"] as? String else { return nil }
                    return ToolCall(id: id, name: name, arguments: args)
                }
                if !calls.isEmpty {
                    // v3.5.11：工具轮不再丢弃 reasoning——把 reasoning_content 存进 thinking(黄色思考气泡)。
                    // Codex/Claude Code 都是"一次流式里先思考/解说后工具"，这里补上非流式/解析路径漏接的思考。
                    // 之前 427 行直接 thinking:nil，模型在工具轮的思考被解析层扔掉。
                    let thinking = (message["reasoning_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    var hasThinking = (thinking != nil && !thinking!.isEmpty)
                    if hasThinking {
                        // 去重：部分中转把完整回答写进 reasoning_content，与 content 相同则弃（避免重复展示）。
                        // 审计修复：content 可能是数组，as? String 会取到 ""，此时 rTrim.contains("") 恒为 true，
                        // 会把思考误删——只在 cText 非空时才做去重比较。
                        let cText = ((message["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim = thinking!
                        if !cText.isEmpty, cText == rTrim || rTrim.contains(cText) || cText.contains(rTrim) {
                            hasThinking = false
                        }
                    }
                    // v3.5.15：透传模型在工具轮写的正文解说(content)，供 runLoop 当 visibleText 兜底。
                    // 此前只带 thinking，非流式 chat/completions 会把模型写的解说丢光(用户实测根因)。
                    var narration = ""
                    if let content = message["content"] {
                        if let str = content as? String { narration = str }
                        else if let arr = content as? [[String: Any]] {
                            for c in arr {
                                let t = c["type"] as? String ?? ""
                                if t == "text" || t == "output_text" || t == "input_text" {
                                    if let tt = c["text"] as? String { narration += tt }
                                }
                            }
                        }
                    }
                    return .toolCalls(calls, thinking: hasThinking ? thinking : nil,
                                     content: narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : narration)
                }
            }
            // v2.9.297：content 兼容 字符串 / 数组 ([{"type":"text","text":"..."}] / [{"type":"output_text","text":"..."}]）
            var text = ""
            if let content = message["content"] {
                if let str = content as? String {
                    text = str
                }
                if let arr = content as? [[String: Any]] {
                    for c in arr {
                        let t = c["type"] as? String ?? ""
                        if t == "text" || t == "output_text" || t == "input_text" {
                            if let tt = c["text"] as? String { text += tt }
                        }
                    }
                    // 数组内没有文本 → 尝试 reasoning_content 里的总结
                    if text.isEmpty {
                        for c in arr {
                            if let rc = c["text"] as? String, !rc.isEmpty {
                                text += rc
                            }
                        }
                    }
                }
            }
            // v3.1.25：同时读取 reasoning_content 存到 thinking (之前被完全忽略了）
            let thinking = (message["reasoning_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // v3.1.33：去重——部分中转/模型把完整回答写进 reasoning_content，与 content 完全相同
            //  (表现：思考内容和发送内容一模一样）。此时丢弃 thinking，避免重复展示。
            var hasThinking = (thinking != nil && !thinking!.isEmpty)
            if hasThinking {
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let t = thinking!
                if !trimmedText.isEmpty && (trimmedText == t || t.contains(trimmedText) || trimmedText.contains(t)) {
                    hasThinking = false
                }
                // 正文为空但 thinking 是完整回答 (模型把回答全放 reasoning）→ 转成正文
                if trimmedText.isEmpty, t.count > 40 {
                    text = t
                    hasThinking = false
                }
            }
            if !text.isEmpty || hasThinking {
                return .text(text, thinking: hasThinking ? thinking : nil)
            }
            return .text("", thinking: nil)
        }
        if let text = firstChoice["text"] as? String {
            return .text(text, thinking: nil)
        }
        return .text("", thinking: nil)
    }

    private func persist(level: Int) {
        DispatchQueue.main.async {
            guard let idx = ModelStore.shared.configs.firstIndex(where: { $0.id == self.config.id }) else { return }
            ModelStore.shared.configs[idx].compatLevel = level
            ModelStore.shared.save()
        }
    }

    // MARK: - Responses API (v2.9.0）

    /// OpenAI /v1/responses 端点 (Codex 同款）。
    /// GPT-5.6 家族的 function tools 在 chat/completions 上不可用/极慢，
    /// 但 Responses API 正常——用户在相同中转上 Codex 可运行即为证据。
    /// v2.9.48：加自动重试 (最多3次，指数退避 1s/2s）——网络错误/5xx/解析failed自动重试，不再需要手动点"继续"。
    private func performResponses(messages: [ChatMessage], tools: [[String: Any]]?, onStatus: ((String) -> Void)?, onThinking: ((String) -> Void)? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/responses") else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 baseURL"])))
            return
        }

        /// 判断某次failed是否值得重试 (网络抖动/5xx/解析failed属于瞬时错误；4xx 参数/鉴权错误不重试）
        func shouldRetry(_ err: NSError, _ statusCode: Int) -> Bool {
            if err.domain == NSURLErrorDomain {
                let c = err.code
                return c == NSURLErrorTimedOut || c == NSURLErrorNetworkConnectionLost
                    || c == NSURLErrorCannotConnectToHost || c == NSURLErrorNotConnectedToInternet
            }
            if statusCode >= 500 { return true }
            let d = err.localizedDescription
            if d.contains("解析failed") || d.contains("无法解析") { return true }
            return false
        }

        func fire(attempt: Int) {
            var request = URLRequest(url: url, timeoutInterval: 90)
            setHTTPMethod("POST", on: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(to: &request)

            var body: [String: Any] = [
                "model": config.model,
                "input": responsesInput(from: messages),
                "max_output_tokens": config.maxTokens
            ]
            if config.isReasoningModel {
                body["reasoning"] = ["effort": reasoningEffortName()]
            }
            if let tools = tools, !tools.isEmpty {
                body["tools"] = tools.map { responsesToolSchema($0) }
                body["tool_choice"] = "auto"
            }
            injectBodyAuth(into: &body)
            applyParamAliases(into: &body)
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            NetworkLog.shared.log("\(config.name) L5 Responses API+工具 → POST /responses，字段: \(body.keys.sorted().joined(separator: ","))")
            if attempt > 0 {
                onStatus?("正在重试 Responses API (第 \(attempt + 1)/3 次)…")
            } else {
                onStatus?("正在通过 Responses API 请求 (保留工具调用)…")
            }

            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                if self.cancelled {
                    completion(.failure(NSError(domain: "OpenAIClient", code: -999,
                        userInfo: [NSLocalizedDescriptionKey: "请求已取消"])))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                // 1) 网络错误
                if let error = error {
                    let nsErr = error as NSError
                    NetworkLog.shared.log("\(self.config.name) L5 网络错误: \(nsErr.localizedDescription)")
                    if attempt < 2 && shouldRetry(nsErr, status) {
                        let delay = Double(1 << attempt)
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { fire(attempt: attempt + 1) }
                        return
                    }
                    completion(.failure(error))
                    return
                }
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"

                // 2) 解析 JSON (v2.9.46 兜底：标准 JSON / 截取 {..} / SSE data: 行）
                if let json = Self.extractJSONObject(raw) {
                    // 2a) API 显式 error
                    if let err = json["error"] as? [String: Any],
                       let msg = err["message"] as? String {
                        let nsErr = NSError(domain: "OpenAIClient", code: status,
                            userInfo: [NSLocalizedDescriptionKey: "Responses API 错误: \(msg)"])
                        if attempt < 2 && shouldRetry(nsErr, status) {
                            DispatchQueue.global().asyncAfter(deadline: .now() + Double(1 << attempt)) { fire(attempt: attempt + 1) }
                            return
                        }
                        let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                        NetworkLog.shared.log("\(self.config.name) L5 failed (HTTP \(status)，耗时 \(el)ms): \(msg)")
                        completion(.failure(nsErr))
                        return
                    }
                    // 2b) 正常 output
                    if let output = json["output"] as? [[String: Any]] {
                        var calls: [ToolCall] = []
                        var text = ""
                        var thinking = ""
                        for item in output {
                            let type = item["type"] as? String ?? ""
                            if type == "function_call",
                               let callId = item["call_id"] as? String,
                               let name = item["name"] as? String,
                               let args = item["arguments"] as? String {
                                calls.append(ToolCall(id: callId, name: name, arguments: args))
                            }
                            if type == "reasoning" {
                                if let summary = item["summary"] as? [[String: Any]] {
                                    for sm in summary { if let st = sm["text"] as? String { thinking += st } }
                                }
                                if let contentArr = item["content"] as? [[String: Any]] {
                                    for cc in contentArr { if let st = cc["text"] as? String { thinking += st } }
                                }
                            }
                            if type == "message",
                               let content = item["content"] as? [[String: Any]] {
                                for c in content where (c["type"] as? String) == "output_text" {
                                    if let t = c["text"] as? String { text += t }
                                }
                            }
                        }
                        let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                        NetworkLog.shared.log("\(self.config.name) L5 (Responses API+工具)请求OK (\(el)ms)，已记忆该级别")
                        NetworkLog.lastCompatNote = "模型「\(self.config.name)」当前兼容级别: 5 (Responses API+工具)"
                        self.persist(level: 5)
                        if !calls.isEmpty {
                            let t = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                            let n = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            completion(.success(.toolCalls(calls, thinking: t.isEmpty ? nil : t, content: n.isEmpty ? nil : n)))
                        } else {
                            let t = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                            completion(.success(.text(text, thinking: t.isEmpty ? nil : t)))
                        }
                        return
                    }
                }

                // 3) 解析failed (非标准 JSON / 无 output）
                let nsErr = NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Responses parse failed: \(raw.prefix(300))"])
                if attempt < 2 && shouldRetry(nsErr, status) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(1 << attempt)) { fire(attempt: attempt + 1) }
                    return
                }
                completion(.failure(nsErr))
            }
            activeTask = task
            task.resume()
        }
        fire(attempt: 0)
    }

    /// v2.9.46：从原始响应体中提取 JSON 对象 (兜底解析，解决"无法解析响应"）。
    /// 兼容：①标准 JSON；②前后夹带日志/空白；③SSE 流 (collected data: 行拼成 JSON）。
    private static func extractJSONObject(_ raw: String) -> [String: Any]? {
        // 1) 直接解析
        if let j = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] { return j }
        // 2) 截取第一个 { 到最后一个 } (夹带前缀/后缀）
        if let i = raw.firstIndex(of: "{"), let j = raw.lastIndex(of: "}"), i < j {
            let sub = String(raw[i...j])
            if let jj = try? JSONSerialization.jsonObject(with: Data(sub.utf8)) as? [String: Any] { return jj }
        }
        // 3) SSE：collected "data: {...}" 或 "data:{...}" 行，拼接后重试
        var sseAccum = ""
        for line in raw.components(separatedBy: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("data:") {
                l = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if l == "[DONE]" { continue }
                sseAccum += l
            }
        }
        if !sseAccum.isEmpty {
            if let j = try? JSONSerialization.jsonObject(with: Data(sseAccum.utf8)) as? [String: Any] { return j }
            if let i = sseAccum.firstIndex(of: "{"), let j = sseAccum.lastIndex(of: "}"), i < j {
                let sub = String(sseAccum[i...j])
                if let jj = try? JSONSerialization.jsonObject(with: Data(sub.utf8)) as? [String: Any] { return jj }
            }
        }
        return nil
    }

    /// v2.9.292：历史图片裁剪——只保留最近 imageBudget 条带图消息的图片，
    /// 更早的图片置空并加文字占位。用于 chat/completions 序列化路径，
    /// 避免历史 base64 图片每次请求全量重发导致 body 巨大 → 卡住/超时。
    private func trimmedMessages(_ messages: [ChatMessage], imageBudget: Int = 2) -> [ChatMessage] {
        var budget = imageBudget
        var out: [ChatMessage] = []
        for m in messages.reversed() {
            var mm = m
            if let imgs = mm.imageDataURLs, !imgs.isEmpty {
                if budget > 0 {
                    budget -= 1
                } else {
                    mm.imageDataURLs = nil
                    mm.content += "\n[图片已省略：历史图片过多，仅保留最近 \(imageBudget) 条]"
                }
            }
            out.append(mm)
        }
        return out.reversed()
    }

    /// 把内部消息历史转换为 Responses API 的 input 数组。
    /// - 普通消息 → {"role": ..., "content": ...}
    /// - assistant 带 toolCalls → message + 逐个 {"type":"function_call", ...}
    /// - tool 结果 → {"type":"function_call_output", ...}
    private func responsesInput(from messages: [ChatMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        // v2.9.292：历史图片裁剪——只保留最近 2 条带图消息的图片，
        // 更早的图片替换为文字占位。否则历史里每张 base64 图每次请求全量重发，
        // body 越积越大 → AI 回消息/看图卡住 (用户实证：新对话发文字才正常）。
        var imgBudget = 2
        for m in messages {
            if m.role == "tool" {
                items.append([
                    "type": "function_call_output",
                    "call_id": m.toolCallId ?? "",
                    "output": m.content
                ])
                continue
            }
            if let calls = m.toolCalls, !calls.isEmpty {
                if !m.content.isEmpty {
                    items.append(["role": "assistant", "content": m.content])
                }
                for c in calls {
                    items.append([
                        "type": "function_call",
                        "call_id": c.id,
                        "name": c.name,
                        "arguments": c.arguments
                    ])
                }
                continue
            }
            // v2.9.9：多模态。图片消息在 Responses API 中同样用 content 数组。
            if let imgs = m.imageDataURLs, !imgs.isEmpty {
                var content: [[String: Any]] = [["type": "input_text", "text": m.content]]
                if imgBudget > 0 {
                    for u in imgs {
                        content.append(["type": "input_image", "image_url": u])
                    }
                } else {
                    content = [["type": "input_text", "text": m.content + "\n[图片已省略：历史图片过多，仅保留最近 2 条]"]]
                }
                imgBudget -= 1
                items.append(["role": m.role, "content": content])
                continue
            }
            items.append(["role": m.role, "content": m.content])
        }
        return items
    }

    /// chat/completions 的嵌套工具 schema → Responses 的扁平格式
    /// {"type":"function","function":{"name":...}} → {"type":"function","name":...}
    private func responsesToolSchema(_ chatTool: [String: Any]) -> [String: Any] {
        if let fn = chatTool["function"] as? [String: Any] {
            var flat: [String: Any] = ["type": "function"]
            if let n = fn["name"] as? String { flat["name"] = n }
            if let d = fn["description"] as? String { flat["description"] = d }
            if let p = fn["parameters"] { flat["parameters"] = p }
            return flat
        }
        return chatTool
    }

    // MARK: - Anthropic

    private func performAnthropic(messages: [ChatMessage], tools: [[String: Any]]? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/messages") else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 baseURL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "messages": trimmedMessages(messages).map { messageDict($0) }
        ]
        // v2.9.175：Anthropic 协议也传工具 (此前完全没传 tools，AI 一个 schema 都看不到，
        // 只能靠 system prompt 文字描述脑补工具名——"app.decrypt 够不到"的根因之一）。
        // OpenAI function schema → Anthropic tools 格式转换。
        if let tools, !tools.isEmpty {
            var anthropicTools: [[String: Any]] = []
            for t in tools {
                guard let fn = t["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let desc = fn["description"] as? String else { continue }
                let params = fn["parameters"] as? [String: Any] ?? [:]
                var inputSchema = params
                inputSchema["type"] = "object"
                anthropicTools.append([
                    "name": name,
                    "description": desc,
                    "input_schema": inputSchema
                ])
            }
            if !anthropicTools.isEmpty {
                body["tools"] = anthropicTools
            }
        }
        // v2.9.107：Anthropic 标准协议 system 提至顶层 (此前 role=system 混在 messages 里，
        // 部分严格中转会拒；同时为 cache_control 断点注入提供 system 块）
        if var msgs = body["messages"] as? [[String: Any]] {
            let systemMsgs = msgs.filter { ($0["role"] as? String) == "system" }
            if !systemMsgs.isEmpty {
                var systemBlocks: [[String: Any]] = []
                for sm in systemMsgs {
                    if let text = sm["content"] as? String, !text.isEmpty {
                        systemBlocks.append(["type": "text", "text": text])
                    }
                }
                if !systemBlocks.isEmpty {
                    body["system"] = systemBlocks
                    msgs.removeAll { ($0["role"] as? String) == "system" }
                    body["messages"] = msgs
                }
            }
            // v2.9.107：cache_control 断点injected (对齐 cc-switch cache_injector 4 断点策略）
            CacheInjector.injectAnthropic(body: &body)
        }
        injectBodyAuth(into: &body)
        applyParamAliases(into: &body)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: request) { data, response, error in
            if self.cancelled {
                completion(.failure(NSError(domain: "OpenAIClient", code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "请求已取消"])))
                return
            }
            if let error = error {
                completion(.failure(error))
                return
            }
            let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
            guard let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] else {
                completion(.failure(NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "parse failed: \(raw.prefix(300))"])))
                return
            }
            if let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                completion(.failure(NSError(domain: "OpenAIClient", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Anthropic 错误: \(msg)"])))
                return
            }
            guard let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String else {
                completion(.failure(NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "parse failed: \(raw.prefix(300))"])))
                return
            }
            completion(.success(.text(text, thinking: nil)))
        }
        activeTask = task
        task.resume()
    }

    // MARK: - 消息序列化

    private func messageDict(_ msg: ChatMessage) -> [String: Any] {
        if msg.role == "tool" {
            return [
                "role": "tool",
                "tool_call_id": msg.toolCallId ?? "",
                "content": msg.content
            ]
        }
        if let calls = msg.toolCalls, !calls.isEmpty {
            return [
                "role": "assistant",
                "content": msg.content,
                "tool_calls": calls.map { [
                    "id": $0.id,
                    "type": "function",
                    "function": ["name": $0.name, "arguments": $0.arguments]
                ] }
            ]
        }
        // v2.9.9：多模态。消息带图片时 content 序列化为多模态数组。
        if let imgs = msg.imageDataURLs, !imgs.isEmpty {
            var content: [[String: Any]] = [["type": "text", "text": msg.content]]
            for u in imgs {
                content.append(["type": "image_url", "image_url": ["url": u]])
            }
            return ["role": msg.role, "content": content]
        }
        return ["role": msg.role, "content": msg.content]
    }

    // MARK: - 鉴权

    private func applyAuth(to request: inout URLRequest) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "Bearer":
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case "API Key":
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        case "Query token":
            if !key.isEmpty, let u = request.url {
                request.url = Self.appendingQueryItem("token", value: key, to: u)
            }
        case "Query api_key":
            if !key.isEmpty, let u = request.url {
                request.url = Self.appendingQueryItem("api_key", value: key, to: u)
            }
        case "None":
            break
        case "Body api_key", "Body token":
            // body 认证：由 injectBodyAuth 在 httpBody 设置前注入到 JSON body 里
            break
        default:
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
    }

    /// body 认证（Body api_key / Body token）：把 key 注入请求体顶层。
    private func injectBodyAuth(into body: inout [String: Any]) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return }
        switch method {
        case "Body api_key":
            body["api_key"] = key
        case "Body token":
            body["token"] = key
        default:
            break
        }
    }

    /// v3.5.13：可配置参数名别名——把 body 里"标准键"重命名为该供应商认的键。
    /// 例：config.paramAliases = {"max_tokens":"max_completion_tokens"}。
    private func applyParamAliases(into body: inout [String: Any]) {
        let aliases = config.paramAliases
        if aliases.isEmpty { return }
        for (standard, alias) in aliases {
            guard !standard.isEmpty, !alias.isEmpty, standard != alias else { continue }
            if let v = body.removeValue(forKey: standard) {
                body[alias] = v
            }
        }
    }

    /// 给 URL 追加单个 query 项（已含 ? 或 &，不重复添加同名键）。
    private static func appendingQueryItem(_ name: String, value: String, to url: URL) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents(string: url.absoluteString)!
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url ?? url
    }

    // MARK: - v2.9.53 SSE 流式

    /// SSE 流式 delegate：接收增量数据，按 \n\n 切分事件，回调 onEvent。
    private class SSEStreamDelegate: NSObject, URLSessionDataDelegate {
        var onEvent: ((String) -> Void)?   // 每个完整 SSE 事件的原始文本
        var onComplete: ((Error?) -> Void)?
        private var buffer = Data()

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            buffer.append(data)
            // SSE 事件以 \n\n 分隔
            while true {
                guard let range = buffer.range(of: Data("\n\n".utf8)) else { break }
                let eventData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                if let text = String(data: eventData, encoding: .utf8) {
                    onEvent?(text)
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
                onEvent?(text)
                buffer.removeAll()
            }
            onComplete?(error)
        }
    }

    /// 解析单个 SSE 事件，返回 (type, delta, fullJson)。
    /// 兼容：event: xxx + data: {...}，或只有 data: {...} (type 在 JSON 里）。
    private func parseSSEEvent(_ raw: String) -> (type: String, delta: String, json: [String: Any])? {
        var eventType = ""
        var dataJson = ""
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("event:") {
                eventType = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("data:") {
                dataJson += String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !dataJson.isEmpty, dataJson != "[DONE]" else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(dataJson.utf8)) as? [String: Any] else { return nil }
        let type = eventType.isEmpty ? (json["type"] as? String ?? "") : eventType
        let delta = json["delta"] as? String ?? ""
        return (type, delta, json)
    }

    /// v2.9.53：Responses API 流式请求 (SSE）。
    /// - onDelta: 文本增量回调 (逐字显示）
    /// - completion: 响应done后回调 (完整 output 解析为 .text / .toolCalls）
    private func performResponsesStream(messages: [ChatMessage], tools: [[String: Any]]?,
                                        onStatus: ((String) -> Void)?,
                                        onDelta: ((String) -> Void)?,
                                        onThinking: ((String) -> Void)? = nil,
                                        completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/responses") else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 baseURL"])))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 90)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)

        var body: [String: Any] = [
            "model": config.model,
            "input": responsesInput(from: messages),
            "max_output_tokens": config.maxTokens,
            "stream": true
        ]
        if config.isReasoningModel {
            body["reasoning"] = ["effort": reasoningEffortName()]
        }
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools.map { responsesToolSchema($0) }
            body["tool_choice"] = "auto"
        }
        injectBodyAuth(into: &body)
        applyParamAliases(into: &body)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        onStatus?("正在流式请求 (Responses API)…")

        // 累积状态
        var fullText = ""
        var fullThinking = ""
        var toolCalls: [ToolCall] = []
        var currentCallId = ""
        var currentCallName = ""
        var currentCallArgs = ""
        var completedResponse: [String: Any]?
        // v2.9.54：首字节超时降级——中转站可能不支持 SSE 流式或缓冲响应，
        // 10 秒内没收到第一个事件就自动切回非流式 performResponses
        var firstByteReceived = false
        var fellBackToNonStream = false

        // v2.9.87：修复流式/非流式双 completion 竞态——
        // firstByteTimer 跑主线程、SSE 回调跑 URLSession 内部队列，
        // 10s 边界上可能两条路径都调 completion (后到覆盖先到 → 回复被吞/重复）。
        // 统一走 guardedCompletion，任何路径只能done一次。
        let completionLock = NSLock()
        var completionCalled = false
        let guardedCompletion: (Result<ChatResult, Error>) -> Void = { r in
            completionLock.lock()
            if completionCalled { completionLock.unlock(); return }
            completionCalled = true
            completionLock.unlock()
            completion(r)
        }

        let delegate = SSEStreamDelegate()
        let streamSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        // 首字节超时定时器 (10 秒）
        let firstByteTimer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !firstByteReceived && !fellBackToNonStream {
                fellBackToNonStream = true
                NetworkLog.shared.log("\(self.config.name): 流式首字节超时 (10s)，自动降级非流式")
                streamSession.invalidateAndCancel()
                // 切回非流式 performResponses (completion 走 guardedCompletion，防双done）
                self.performResponses(messages: messages, tools: tools, onStatus: onStatus, onThinking: onThinking, completion: guardedCompletion)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: firstByteTimer)

        delegate.onEvent = { [weak self] raw in
            guard let self = self else { return }
            if !firstByteReceived {
                firstByteReceived = true
                firstByteTimer.cancel()
                // v2.9.88：链路可视化 —— 首字节到达即上报"已连接，开始流式接收"
                let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                NetworkLog.shared.log("\(self.config.name): 流式首字节 (\(el)ms)")
                onStatus?("已连接 · 首字节 \(String(format: "%.1f", Double(el) / 1000.0))s，开始接收…")
            }
            if fellBackToNonStream { return }
            guard let ev = self.parseSSEEvent(raw) else { return }
            let type = ev.type

            // 文本增量 → 逐字显示
            if type == "response.text.delta", !ev.delta.isEmpty {
                fullText += ev.delta
                DispatchQueue.main.async { onDelta?(ev.delta) }
            }
            // 推理增量 → v2.9.127 实时思考 (打字机式逐句显示）
            if type == "response.reasoning.delta", !ev.delta.isEmpty {
                fullThinking += ev.delta
                let d = ev.delta
                DispatchQueue.main.async { onThinking?(d) }
            }
            // 工具调用开始
            if type == "response.output_item.added",
               let item = ev.json["item"] as? [String: Any],
               item["type"] as? String == "function_call",
               let callId = item["call_id"] as? String,
               let name = item["name"] as? String {
                currentCallId = callId
                currentCallName = name
                currentCallArgs = ""
            }
            // 工具参数增量
            if type == "response.function_call_arguments.delta", !ev.delta.isEmpty {
                currentCallArgs += ev.delta
            }
            // 工具调用done
            if type == "response.output_item.done",
               let item = ev.json["item"] as? [String: Any],
               item["type"] as? String == "function_call" {
                if !currentCallId.isEmpty {
                    toolCalls.append(ToolCall(id: currentCallId, name: currentCallName, arguments: currentCallArgs))
                }
                currentCallId = ""
                currentCallName = ""
                currentCallArgs = ""
            }
            // 响应done (包含完整 response 对象）
            if type == "response.completed",
               let response = ev.json["response"] as? [String: Any] {
                completedResponse = response
            }
        }

        delegate.onComplete = { [weak self] error in
            guard let self = self else { return }
            firstByteTimer.cancel()
            streamSession.invalidateAndCancel()
            // v2.9.54：已降级到非流式，不重复执行 completion
            if fellBackToNonStream { return }

            if let error = error {
                guardedCompletion(.failure(error))
                return
            }

            // 如果 response.completed 里有完整 output，优先用它 (更准确）
            if let resp = completedResponse, let output = resp["output"] as? [[String: Any]] {
                var calls: [ToolCall] = []
                var text = ""
                var thinking = ""
                for item in output {
                    let t = item["type"] as? String ?? ""
                    if t == "function_call",
                       let callId = item["call_id"] as? String,
                       let name = item["name"] as? String,
                       let args = item["arguments"] as? String {
                        calls.append(ToolCall(id: callId, name: name, arguments: args))
                    }
                    if t == "reasoning" {
                        if let summary = item["summary"] as? [[String: Any]] {
                            for sm in summary { if let st = sm["text"] as? String { thinking += st } }
                        }
                        if let contentArr = item["content"] as? [[String: Any]] {
                            for cc in contentArr { if let st = cc["text"] as? String { thinking += st } }
                        }
                    }
                    if t == "message", let content = item["content"] as? [[String: Any]] {
                        for c in content where (c["type"] as? String) == "output_text" {
                            if let tt = c["text"] as? String { text += tt }
                        }
                    }
                }
                // v2.9.297：L5 空响应 (output 无文本无工具调用）判为failed——中转站可能不支持 Responses API
                if calls.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NetworkLog.shared.log("\(self.config.name): Responses API 返回空 output，判定不支持，回落 chat/completions")
                    guardedCompletion(.failure(NSError(domain: "OpenAIClient", code: -3040,
                        userInfo: [NSLocalizedDescriptionKey: "模型返回空响应 (中转站可能不支持 Responses API)"])))
                    return
                }
                self.persist(level: 5)
                NetworkLog.lastCompatNote = "模型「\(self.config.name)」当前兼容级别: 5 (Responses API+工具，流式)"
                if !calls.isEmpty {
                    let n = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guardedCompletion(.success(.toolCalls(calls, thinking: nil, content: n.isEmpty ? nil : n)))
                } else {
                    var th = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    // v3.1.33：去重——reasoning 与正文相同时不展示思考
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !th.isEmpty, !trimmedText.isEmpty, (trimmedText == th || th.contains(trimmedText) || trimmedText.contains(th)) {
                        th = ""
                    }
                    // 正文为空但 thinking 是完整回答 → 转成正文
                    if th.isEmpty, trimmedText.isEmpty, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       thinking.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
                        text = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    // v2.9.127：非流式兜底——整段思考一次性推送 (降级场景也能显示思考）
                    if !th.isEmpty {
                        let whole = th
                        DispatchQueue.main.async { onThinking?(whole) }
                    }
                    guardedCompletion(.success(.text(text, thinking: th.isEmpty ? nil : th)))
                }
                return
            }

            // fallback：用流式过程中累积的数据
            // v2.9.297：流式零增量且无 completedResponse 输出 → 判failed回落
            if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCalls.isEmpty && fullThinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NetworkLog.shared.log("\(self.config.name): Responses 流式无任何文本/工具增量，判定不支持，回落 chat/completions")
                guardedCompletion(.failure(NSError(domain: "OpenAIClient", code: -3041,
                    userInfo: [NSLocalizedDescriptionKey: "模型返回空响应 (中转站可能不支持 Responses API)"])))
                return
            }
            self.persist(level: 5)
            if !toolCalls.isEmpty {
                let n = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                guardedCompletion(.success(.toolCalls(toolCalls, thinking: nil, content: n.isEmpty ? nil : n)))
            } else {
                var th = fullThinking.trimmingCharacters(in: .whitespacesAndNewlines)
                // v3.1.33：去重——思考与正文相同时不展示
                let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !th.isEmpty, !trimmedText.isEmpty, (trimmedText == th || th.contains(trimmedText) || trimmedText.contains(th)) {
                    th = ""
                }
                guardedCompletion(.success(.text(fullText, thinking: th.isEmpty ? nil : th)))
            }
        }

        let task = streamSession.dataTask(with: request)
        activeTask = task
        task.resume()
    }
}

// MARK: - Anthropic cache_control 断点injected (v2.9.107，对齐 cc-switch cache_injector 4 断点策略）
// Anthropic 缓存上限 4 个断点；已存在的标记保留 (caller-owned），budget = 4 - existing。

enum CacheInjector {
    static func injectAnthropic(body: inout [String: Any]) {
        var budget = 4
        // (a) tools 数组最后一个元素
        if budget > 0, var tools = body["tools"] as? [[String: Any]], var last = tools.last, last["cache_control"] == nil {
            last["cache_control"] = ["type": "ephemeral"]
            tools[tools.count - 1] = last
            body["tools"] = tools
            budget -= 1
        }
        // (b) system 顶层数组末尾
        if budget > 0, var system = body["system"] as? [[String: Any]], var last = system.last, last["cache_control"] == nil {
            last["cache_control"] = ["type": "ephemeral"]
            system[system.count - 1] = last
            body["system"] = system
            budget -= 1
        }
        // (c) 最新一条消息的非 thinking block
        if budget > 0, var messages = body["messages"] as? [[String: Any]] {
            for i in stride(from: messages.count - 1, through: 0, by: -1) {
                if injectMessage(&messages[i]) {
                    body["messages"] = messages
                    budget -= 1
                    break
                }
            }
            // (d) 更早的第 2 个 user 锚点 (应对长工具循环超出 20-block lookback）
            if budget > 0, messages.count >= 4 {
                var userCount = 0
                for i in stride(from: messages.count - 1, through: 0, by: -1) {
                    if messages[i]["role"] as? String == "user" {
                        userCount += 1
                        if userCount == 2 {
                            var m = messages[i]
                            if injectMessage(&m) {
                                messages[i] = m
                                body["messages"] = messages
                                budget -= 1
                            }
                            break
                        }
                    }
                }
            }
        }
    }

    private static func injectMessage(_ message: inout [String: Any]) -> Bool {
        guard var content = message["content"] as? [Any] else { return false }
        for i in stride(from: content.count - 1, through: 0, by: -1) {
            guard var block = content[i] as? [String: Any] else { continue }
            let type = block["type"] as? String
            if type == "thinking" || type == "redacted_thinking" { continue }
            if block["cache_control"] != nil { return false }
            block["cache_control"] = ["type": "ephemeral"]
            content[i] = block
            message["content"] = content
            return true
        }
        return false
    }
}

// MARK: - 用量记录 (v2.9.107，本地 JSONL，供「用量统计」页聚合）

final class UsageRecorder {
    static let shared = UsageRecorder()

    private let fileURL: URL
    private let lock = NSLock()
    private var lastStart = Date()
    private var lastInputEst = 0

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("trollagent_usage.jsonl")
    }

    func begin(messages: [ChatMessage]) {
        lastStart = Date()
        var est = 0
        for m in messages {
            let ch = m.content.count
            let imgs = (m.imageDataURLs?.count ?? 0) * 1000
            est += ch / 3 + imgs + 8
        }
        lastInputEst = est
    }

    func end(config: ModelConfig, ok: Bool, elapsedMs: Int, error: String = "") {
        lock.lock(); defer { lock.unlock() }
        let rec: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "name": config.name,
            "provider": config.provider,
            "baseURL": config.baseURL,
            "model": config.model,
            "ok": ok,
            "elapsedMs": elapsedMs,
            "error": error,
            "estInputTokens": lastInputEst
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: rec) else { return }
        if let fh = try? FileHandle(forWritingTo: fileURL) {
            fh.seekToEndOfFile()
            fh.write(d)
            fh.write(Data("\n".utf8))
            try? fh.close()
        } else {
            try? d.write(to: fileURL)
        }
    }

    var records: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in s.split(separator: "\n").suffix(500) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(String(line).utf8)) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
