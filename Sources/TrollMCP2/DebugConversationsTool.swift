import Foundation

/// v2.9.295：调试工具——导出会话标题与首条消息内容
/// 用途：排查"对话标题乱码/不更新"问题时，远程直接看手机上的真实会话数据
final class DebugDumpConversationsTool: MCPTool {
    let definition = ToolDefinition(
        name: "debug.dump_conversations",
        summary: "Debug: export list of chat conversations. Use for: debug conversation issues, see what chats exist internally. Don't use for: read a specific conversation (use debug.dump_messages), list skills (use skills.list). Example: user says 'export conversation list' → dump conversations.",
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

/// v3.1.26：调试工具——导出单个对话的完整消息列表
/// 用途：远程调试 AI 行为，看 AI 是怎么思考和调用工具的
final class DebugDumpConversationTool: MCPTool {
    let definition = ToolDefinition(
        name: "debug.dump_conversation",
        summary: "Debug: export full messages of one conversation. Use for: debug AI behavior, see how AI thinks and calls tools. Don't use for: list all conversations (use debug.dump_conversations), send a message (use chat.send). Example: user says 'see the recent conversation' → dump conversation messages.",
        parameters: ["title": "Conversation title to export (e.g. 'Hello')", "limit": "Max messages to return (default: 50, max: 200)"], verified: true, category: "debug", remoteOnly: true)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String, !title.isEmpty else {
            throw MCPError.invalidParams("title required")
        }
        let limit = max(1, min((params["limit"] as? Int) ?? 50, 200))
        let convs = ConversationStore.shared.conversations
        guard let conv = convs.first(where: { $0.title == title }) else {
            throw MCPError.failed("conversation not found: \(title)")
        }
        let messages = Array(conv.messages.suffix(limit))
        return [
            "title": conv.title,
            "totalMessages": conv.messages.count,
            "returnedMessages": messages.count,
            "messages": messages.map { msg -> [String: Any] in
                var dict: [String: Any] = [
                    "role": msg.role,
                    "content": msg.content,
                    "timestamp": msg.timestamp.timeIntervalSince1970,
                    "isError": msg.isError
                ]
                // v3.1.26：加上 thinking / toolName / toolArgs 便于远程调试 UI
                if let t = msg.thinking, !t.isEmpty { dict["thinking"] = t }
                if let n = msg.toolName { dict["toolName"] = n }
                if let a = msg.toolArgs { dict["toolArgs"] = a }
                return dict
            }
        ]
    }
}

/// v3.1.26：模型工具——列出所有模型配置
final class ModelListTool: MCPTool {
    let definition = ToolDefinition(
        name: "model.list",
        summary: "List all AI model configurations. Use for: see what models are available, debug model switching. Don't use for: change model (use model.switch), dump debug info (use debug.dump_model_configs). Example: user says 'which models are available' → list models.",
        parameters: [:], verified: true, category: "debug", remoteOnly: true)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let configs = ModelStore.shared.configs.map { cfg -> [String: Any] in
            [
                "id": cfg.id.uuidString,
                "name": cfg.name,
                "provider": cfg.provider,
                "model": cfg.model,
                "isDefault": cfg.isDefault
            ]
        }
        return [
            "total": configs.count,
            "defaultModel": ModelStore.shared.defaultConfig?.name ?? "(无)",
            "models": configs
        ]
    }
}

/// v3.1.26：模型工具——切换当前使用的模型
final class ModelSwitchTool: MCPTool {
    let definition = ToolDefinition(
        name: "model.switch",
        summary: "Switch current AI model. Use for: test different models, switch to a faster/smaller model. Don't use for: list models (use model.list), edit model settings (use settings). Example: user says 'switch to DeepSeek model' → switch model.",
        parameters: ["name": "Model name to switch to (e.g. 'DeepSeek V4')"], verified: true, category: "debug", remoteOnly: true)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        guard let config = ModelStore.shared.configs.first(where: { $0.name == name }) else {
            throw MCPError.failed("model not found: \(name)")
        }
        ModelStore.shared.markUsed(config.id.uuidString)
        return [
            "switched": true,
            "name": config.name,
            "model": config.model,
            "provider": config.provider,
            "note": "Model switched. New messages will use this model."
        ]
    }
}

