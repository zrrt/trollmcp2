# -*- coding: utf-8 -*-
import io

# ============ 1. Models.swift: ModelAPIClient.sendChat ============
path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\Models.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

# 找 applyAuth 定义，在它前面插入 sendChat
anchor = "    private func applyAuth("
assert anchor in c, 'applyAuth not found'

sendchat = '''
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
                                                userInfo: [NSLocalizedDescriptionKey: "解析失败: \\(raw.prefix(200))"])))
                }
            }
        }.resume()
    }

'''
c = c.replace(anchor, sendchat + anchor, 1)
with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('ADDED sendChat')
