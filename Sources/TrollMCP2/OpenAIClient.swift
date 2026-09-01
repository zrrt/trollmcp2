import Foundation
import Combine

enum ChatResult {
    case text(String)
    case toolCalls([ToolCall])
}

/// 网络调试日志（最近 100 条，环形覆盖），用于排查中转站兼容性问题。
/// 界面上在「设置 → 关于 → 网络兼容日志」查看。
final class NetworkLog: ObservableObject {
    static let shared = NetworkLog()

    /// 最近一条兼容性日志（供设置页副标题展示）
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

/// 兼容 API 客户端（OpenAI / DeepSeek / Anthropic / 任意兼容端点）。
///
/// v2.8.4：针对中转站（new-api 系）"Invalid request parameter" 报错实现**自适应兼容降级**。
/// 不同中转站 / 不同模型对参数的支持差异极大（部分不认 max_completion_tokens、
/// 部分不支持 tool_choice、部分模型族在 chat/completions 上拒绝 tools），
/// 与其猜测，不如让客户端自己逐级试探并记住可用级别：
///
/// | 级别 | 载荷 |
/// |------|------|
/// | 0 | 完整载荷（tools + tool_choice + 推理模型参数适配） |
/// | 1 | 0 基础上互换 token key（max_completion_tokens ↔ max_tokens） |
/// | 2 | 1 基础上去掉 tool_choice |
/// | 3 | 1 基础上去掉 tools（纯对话；历史中的 tool 消息降级为普通文本） |
/// | 4 | 最小载荷（仅 model + messages） |
///
/// 成功后把可用级别持久化到 ModelConfig.compatLevel，下次直接从该级别发起。
final class OpenAIClient {
    let config: ModelConfig
    private let maxLevel = 4

    init(_ config: ModelConfig) {
        self.config = config
    }

    // MARK: - 对外入口

    func send(messages: [ChatMessage], tools: [[String: Any]]? = nil, onStatus: ((String) -> Void)? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let start = min(max(config.compatLevel, 0), maxLevel)
        if start > 0 {
            NetworkLog.shared.log("\(config.name): 使用已记忆的兼容级别 \(start)（\(levelName(start))）")
        } else {
            NetworkLog.shared.log("\(config.name): 发起请求（级别 0 完整载荷）")
        }
        attempt(level: start, isFirst: true, messages: messages, tools: tools, onStatus: onStatus, completion: completion)
    }

    // MARK: - 逐级试探

    private func attempt(level: Int, isFirst: Bool, messages: [ChatMessage], tools: [[String: Any]]?, onStatus: ((String) -> Void)?, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        if config.apiProtocol == "Anthropic Messages" {
            performAnthropic(messages: messages, completion: completion)
            return
        }

        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = config.apiProtocol == "OpenAI Completions" ? "/completions" : "/chat/completions"
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 baseURL"])))
            return
        }

        // v2.8.6：首次请求 45s；降级重试 30s。
        // 中转对完整载荷（tools + reasoning_effort）处理极慢/卡死，尽早超时并降级。
        var request = URLRequest(url: url, timeoutInterval: isFirst ? 45 : 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        let body = buildBody(level: level, messages: messages, tools: tools)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // 记录发送的载荷摘要（不含 apiKey），便于排查
        NetworkLog.shared.log("\(config.name) L\(level) \(levelName(level)) → POST \(endpoint)，字段: \(body.keys.sorted().joined(separator: ","))")
        if isFirst {
            onStatus?("正在等待模型响应…")
        } else {
            onStatus?("请求被拒绝，正在尝试简化参数（级别 \(level)/\(maxLevel)）…")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                let err = error as NSError
                // v2.8.6：网络超时（不是 408 HTTP 状态，而是 URLSession 的 -1001）
                // 也可能是中转对完整载荷处理太慢/卡死，降级到轻量载荷很可能成功。
                let isTimeout = (err.code == NSURLErrorTimedOut
                    || err.domain == NSURLErrorDomain && err.code == -1001
                    || error.localizedDescription.contains("超时")
                    || error.localizedDescription.localizedLowercase.contains("timed out"))
                if isTimeout, level < self.maxLevel {
                    NetworkLog.shared.log("\(self.config.name) L\(level) 请求超时 → 自动降级到 L\(level + 1)（\(self.levelName(level + 1))）")
                    onStatus?("请求超时，正在尝试简化参数（级别 \(level + 1)/\(self.maxLevel)）…")
                    self.attempt(level: level + 1, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, completion: completion)
                    return
                }
                // 其它网络错误（断网等）降级无意义
                NetworkLog.shared.log("\(self.config.name) L\(level) 网络错误: \(error.localizedDescription)")
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

            // 成功解析 choices
            if errorPayload == nil,
               let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first {
                if level != self.config.compatLevel {
                    NetworkLog.shared.log("\(self.config.name) 级别 \(level)（\(self.levelName(level))）请求成功，已记忆该级别")
                    NetworkLog.lastCompatNote = "模型「\(self.config.name)」当前兼容级别: \(level)（\(self.levelName(level))）"
                    self.persist(level: level)
                }
                completion(.success(self.parseChoice(firstChoice)))
                return
            }

            // 失败：判断是否可通过降级重试挽救
            let retryable = self.isRetryable(status: status, errorPayload: errorPayload)
            let failMsg = errorPayload ?? raw
            NetworkLog.shared.log("\(self.config.name) L\(level) 失败 (HTTP \(status)): \(String(failMsg.prefix(200)))")

            if retryable && level < self.maxLevel {
                NetworkLog.shared.log("\(self.config.name) 自动降级 → 级别 \(level + 1)（\(self.levelName(level + 1))）")
                self.attempt(level: level + 1, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, completion: completion)
            } else {
                let hint = errorPayload != nil ? "" : "\n提示: 响应非标准 OpenAI 格式，请检查 baseURL 是否指向 /v1 兼容端点。"
                completion(.failure(NSError(domain: "OpenAIClient", code: status,
                    userInfo: [NSLocalizedDescriptionKey: "请求被拒绝 (HTTP \(status)，已尝试到级别 \(level)·\(self.levelName(level)))\n\(String(failMsg.prefix(300)))\(hint)"])))
            }
        }.resume()
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

        if config.apiProtocol == "OpenAI Completions" {
            let prompt = sanitized.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
            if level >= 2 {
                return ["model": config.model, "prompt": prompt]
            }
            var body: [String: Any] = [
                "model": config.model,
                "prompt": prompt,
                tokenKey(level: level): config.maxTokens
            ]
            if level < 2, config.sendsTemperature {
                body["temperature"] = config.temperature
            }
            return body
        }

        // OpenAI Chat Completions / Custom Endpoint
        if level >= 4 {
            return ["model": config.model, "messages": sanitized.map { messageDict($0) }]
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": sanitized.map { messageDict($0) },
            tokenKey(level: level): config.maxTokens
        ]
        if level < 3, config.sendsTemperature {
            body["temperature"] = config.temperature
        }
        // v2.8.5：推理模型（gpt-5.x/o 系）显式关闭 reasoning。
        // 1) 默认 medium 档会先长时间"思考"，是聊天转圈半天的主因；
        // 2) GPT-5.6 家族在 chat/completions 上 tools+默认 reasoning 组合会被拒，
        //    社区报告设为 none 后 tools 可用。
        // 级别 4（最小载荷）不带该字段——若中转连这个字段都不认，还有最后一级兜底。
        if config.isReasoningModel {
            body["reasoning_effort"] = "none"
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

    /// 级别 0 用模型偏好的 key；级别 1 互换（中转站可能只认其中一个）
    private func tokenKey(level: Int) -> String {
        let preferred = config.maxTokensKey
        if level == 1 { return preferred == "max_completion_tokens" ? "max_tokens" : "max_completion_tokens" }
        return preferred
    }

    private func levelName(_ level: Int) -> String {
        switch level {
        case 0: return "完整载荷"
        case 1: return "互换token参数名"
        case 2: return "去掉tool_choice"
        case 3: return "去掉tools纯对话"
        case 4: return "最小载荷"
        default: return "未知"
        }
    }

    /// 4xx 参数类错误可通过降级挽救；
    /// 5xx 网关/上游超时（尤其 tools 过多导致 relay/gpt-5.6 超时或 500）降级到轻量载荷可能成功；
    /// 鉴权(401/402/403)、配额(429) 不降级。
    private func isRetryable(status: Int, errorPayload: String?) -> Bool {
        if status == 401 || status == 402 || status == 403 || status == 429 { return false }
        if status >= 400 && status < 500 { return true }
        // 502/503/504：网关错误 / 上游处理超时；500：terra 处理 tools 超限时报 server_error
        if status == 500 || status == 502 || status == 503 || status == 504 { return true }
        // HTTP 200 + error body（new-api 中转常见）：只有参数类错误才降级
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
                    return .toolCalls(calls)
                }
            }
            if let content = message["content"] as? String {
                return .text(content)
            }
            return .text("")
        }
        if let text = firstChoice["text"] as? String {
            return .text(text)
        }
        return .text("")
    }

    private func persist(level: Int) {
        DispatchQueue.main.async {
            guard let idx = ModelStore.shared.configs.firstIndex(where: { $0.id == self.config.id }) else { return }
            ModelStore.shared.configs[idx].compatLevel = level
            ModelStore.shared.save()
        }
    }

    // MARK: - Anthropic

    private func performAnthropic(messages: [ChatMessage], completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/messages") else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 baseURL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "messages": messages.map { messageDict($0) }
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
            guard let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] else {
                completion(.failure(NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "解析失败: \(raw.prefix(300))"])))
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
                    userInfo: [NSLocalizedDescriptionKey: "解析失败: \(raw.prefix(300))"])))
                return
            }
            completion(.success(.text(text)))
        }.resume()
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
        return ["role": msg.role, "content": msg.content]
    }

    // MARK: - 鉴权

    private func applyAuth(to request: inout URLRequest) {
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
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}
