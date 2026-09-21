import Foundation

/// v2.9.295：调试工具——导出会话标题与首条消息内容
/// 用途：排查"对话标题乱码/不更新"问题时，远程直接看手机上的真实会话数据
final class DebugDumpConversationsTool: MCPTool {
    let definition = ToolDefinition(
        name: "debug.dump_conversations",
        summary: "Debug: export list of chat conversations. Use for: debug conversation issues, see what chats exist internally. Don't use for: read a specific conversation (use debug.dump_messages), list skills (use skills.list). Example: user says '导出一下对话列表' → dump conversations.",
        parameters: ["limit": "How many conversations to export (default: 5, max: 30)"], verified: true, category: "debug")

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
        summary: "Debug: export AI API request logs. Use for: diagnose why AI is not replying, see API errors. Don't use for: capture app network traffic (use network.capture), collect app crash logs (use log.collect). Example: user says 'AI 怎么不回复我，看看网络日志' → dump network log.",
        parameters: ["limit": "How many log entries to show (default: 50, max: 100)"], verified: true, category: "debug")

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
        summary: "Debug: export AI model configuration. Use for: check what model is configured, debug AI connection issues. Don't use for: change model (use model.selectedProfileID), update model settings (use model.update). Example: user says '看看模型配置对不对' → dump model configs.",
        parameters: [:], verified: true, category: "debug")

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
