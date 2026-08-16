import Foundation

/// OpenAI 兼容 API 客户端（支持 OpenAI / DeepSeek / 任何 /v1/chat/completions 兼容端点）
final class OpenAIClient {
    let config: ModelConfig

    init(_ config: ModelConfig) {
        self.config = config
    }

    func send(messages: [ChatMessage], completion: @escaping (Result<String, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 baseURL"])))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": config.temperature,
            "max_tokens": config.maxTokens
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
                completion(.failure(NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "解析失败: \(raw.prefix(300))"])))
                return
            }
            completion(.success(content))
        }.resume()
    }
}
