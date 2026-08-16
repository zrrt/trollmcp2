import Foundation

/// 最小 JSON-RPC 2.0 处理器（tools/list + tools/call）。
/// M1 阶段直接进程内调用；M4 接 Gateway 时同一套分发逻辑套上 WebSocket 传输。
public enum JSONRPC {
    public static func handle(_ data: Data, registry: ToolRegistry = .shared) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            return encode(errorResponse(id: nil, code: -32700, message: "parse error"))
        }
        let id = obj["id"]
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(response(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]] as [String: Any],
                "serverInfo": ["name": "TrollMCP2", "version": "2.0.0-m1"],
            ]))
        case "tools/list":
            let list: [[String: Any]] = registry.definitions.map { def in
                [
                    "name": def.name,
                    "description": def.summary,
                    "parameters": def.parameters,
                ]
            }
            return encode(response(id: id, result: ["tools": list]))
        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return encode(errorResponse(id: id, code: -32602, message: "params.name required"))
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try registry.dispatch(name: toolName, params: args)
                return encode(response(id: id, result: [
                    "content": [["type": "text", "text": jsonString(from: result)]],
                ]))
            } catch let e as MCPError {
                return encode(errorResponse(id: id, code: -32000, message: e.description))
            } catch {
                return encode(errorResponse(id: id, code: -32000, message: String(describing: error)))
            }
        default:
            return encode(errorResponse(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    // MARK: - 私有

    private static func response(id: Any?, result: [String: Any]) -> [String: Any] {
        var dict: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { dict["id"] = id }
        return dict
    }

    private static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        var dict: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id = id { dict["id"] = id }
        return dict
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    private static func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
