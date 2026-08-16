import Foundation

enum ChatResult {
    case text(String)
    case toolCalls([ToolCall])
}

/// 兼容 API 客户端（OpenAI / DeepSeek / Anthropic / 任意兼容端点）
final class OpenAIClient {
    let config: ModelConfig

    init(_ config: ModelConfig) {
        self.config = config
    }

    func send(messages: [ChatMessage], tools: [[String: Any]]? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if config.apiProtocol == "Anthropic Messages" {
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
                "messages": messages.map { messageDict($0) },
                "temperature": config.temperature
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            URLSession.shared.dataTask(with: request) { data, _, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let first = content.first,
                      let text = first["text"] as? String else {
                    let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
                    completion(.failure(NSError(domain: "OpenAIClient", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "解析失败: \(raw.prefix(300))"])))
                    return
                }
                completion(.success(.text(text)))
            }.resume()
            return
        }

        // OpenAI Chat Completions / Completions / Custom
        let endpoint = config.apiProtocol == "OpenAI Completions" ? "/completions" : "/chat/completions"
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 baseURL"])))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        var body: [String: Any]
        if config.apiProtocol == "OpenAI Completions" {
            let prompt = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
            body = [
                "model": config.model,
                "prompt": prompt,
                "temperature": config.temperature,
                "max_tokens": config.maxTokens
            ]
        } else {
            body = [
                "model": config.model,
                "messages": messages.map { messageDict($0) },
                "temperature": config.temperature,
                "max_tokens": config.maxTokens
            ]
            if let tools = tools, !tools.isEmpty {
                body["tools"] = tools
                body["tool_choice"] = "auto"
            }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first else {
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
                completion(.failure(NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "解析失败: \(raw.prefix(300))"])))
                return
            }
            guard let message = firstChoice["message"] as? [String: Any] else {
                if let text = firstChoice["text"] as? String {
                    completion(.success(.text(text)))
                    return
                }
                completion(.failure(NSError(domain: "OpenAIClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法提取回复内容"])))
                return
            }

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
                    completion(.success(.toolCalls(calls)))
                    return
                }
            }

            if let content = message["content"] as? String {
                completion(.success(.text(content)))
                return
            }
            completion(.success(.text("")))
        }.resume()
    }

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
