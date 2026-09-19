import Foundation

/// v2.9.295：调试工具——导出会话标题与首条消息内容
/// 用途：排查"对话标题乱码/不更新"问题时，远程直接看手机上的真实会话数据
final class DebugDumpConversationsTool: MCPTool {
    let definition = ToolDefinition(
        name: "debug.dump_conversations",
        summary: "调试：导出会话列表（标题/消息数/首条消息内容），排查标题乱码问题",
        parameters: ["limit": "最多导出几个会话（默认5，上限30）"], verified: true)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let limit = max(1, min((params["limit"] as? Int) ?? 5, 30))
        let convs = ConversationStore.shared.conversations
        var arr: [[String: Any]] = []
        for c in convs.prefix(limit) {
            let first = c.messages.first
            let last = c.messages.last
            arr.append([
                "title": c.title,
                "messageCount": c.messages.count,
                "firstRole": first?.role ?? "",
                "firstContent": String((first?.content ?? "").prefix(200)),
                "lastRole": last?.role ?? "",
                "lastContent": String((last?.content ?? "").prefix(200)),
                "createdAt": c.createdAt.timeIntervalSince1970
            ])
        }
        return ["total": convs.count, "conversations": arr]
    }
}

/// v2.9.297：调试工具——导出网络日志（最近100条请求/降级/错误记录），排查AI不回消息
final class DebugDumpNetworkLogTool: MCPTool {
    let definition = ToolDefinition(
        name: "debug.dump_network_log",
        summary: "调试：导出NetworkLog最近请求日志（降级/错误/HTTP状态），排查AI请求失败与空回复",
        parameters: ["limit": "最多返回几条（默认50，上限100）"], verified: true)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let limit = max(1, min((params["limit"] as? Int) ?? 50, 100))
        let entries = Array(NetworkLog.shared.entries.prefix(limit))
        return ["total": NetworkLog.shared.entries.count, "entries": entries, "lastCompatNote": NetworkLog.lastCompatNote ?? "(无)"]
    }
}

/// v2.9.296：调试工具——导出模型配置（key 掩码）与当前请求状态
final class DebugDumpModelConfigsTool: MCPTool {
    let definition = ToolDefinition(
        name: "debug.dump_model_configs",
        summary: "调试：导出模型配置（baseURL/模型名/key掩码）与当前请求状态（isLoading/statusText/轮数），排查AI不回消息",
        parameters: [:], verified: true)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let configs = ModelStore.shared.configs.map { cfg -> [String: Any] in
            var c: [String: Any] = [
                "name": cfg.name,
                "provider": cfg.provider,
                "apiProtocol": cfg.apiProtocol,
                "baseURL": cfg.baseURL,
                "model": cfg.model,
                "authMethod": cfg.authMethod,
                "group": cfg.group,
                "isDefault": cfg.isDefault,
                "contextTokens": cfg.contextTokens,
                "compatLevel": cfg.compatLevel
            ]
            let key = cfg.apiKey
            c["apiKeyMasked"] = key.isEmpty ? "(空)" : String(key.prefix(6)) + "…" + String(key.suffix(4))
            return c
        }
        let store = ConversationStore.shared
        return [
            "configs": configs,
            "count": configs.count,
            "defaultConfigName": ModelStore.shared.defaultConfig?.name ?? "(无)",
            "request": [
                "isLoading": store.isLoading,
                "statusText": store.statusText ?? "(nil)",
                "requestRound": store.requestRound,
                "requestRounds": store.requestRounds
            ]
        ]
    }
}
