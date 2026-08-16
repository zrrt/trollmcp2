import Foundation

/// 兼容 API 客户端（OpenAI / DeepSeek / Anthropic / 任意兼容端点）
final class OpenAIClient {
    let config: ModelConfig

    init(_ config: ModelConfig) {
        self.config = config
    }

    func send(messages: [ChatMessage], completion: @escaping (Result<String, Error>) -> Void) {
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
                "messages": messages.map { ["role": $0.role, "content": $0.content] },
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
                completion(.success(text))
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

        let body: [String: Any]
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
                "messages": messages.map { ["role": $0.role, "content": $0.content] },
                "temperature": config.temperature,
                "max_tokens": config.maxTokens
            ]
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
            if let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                completion(.success(content))
                return
            }
            if let text = firstChoice["text"] as? String {
                completion(.success(text))
                return
            }
            completion(.failure(NSError(domain: "OpenAIClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法提取回复内容"])))
        }.resume()
    }

    private func applyAuth(to request: inout URLRequest) {
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
