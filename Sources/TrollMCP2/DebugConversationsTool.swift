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

/// v3.1.26：调试工具——导出单个对话的完整消息列表
/// 用途：远程调试 AI 行为，看 AI 是怎么思考和调用工具的
final class DebugDumpConversationTool: MCPTool {
    let definition = ToolDefinition(
        name: "debug.dump_conversation",
        summary: "Debug: export full messages of one conversation. Use for: debug AI behavior, see how AI thinks and calls tools. Don't use for: list all conversations (use debug.dump_conversations), send a message (use chat.send). Example: user says '看看刚才的对话记录' → dump conversation messages.",
        parameters: ["title": "Conversation title to export (e.g. '您好')", "limit": "Max messages to return (default: 50, max: 200)"], verified: true, category: "debug")

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
                [
                    "role": msg.role,
                    "content": msg.content,
                    "timestamp": msg.timestamp.timeIntervalSince1970,
                    "isError": msg.isError
                ]
            }
        ]
    }
}

/// v3.1.26：聊天工具——发送消息到聊天窗口
/// 用途：远程测试 AI，发消息 → 读取回复 → 看 AI 是怎么调用工具的
final class ChatSendTool: MCPTool {
    let definition = ToolDefinition(
        name: "chat.send",
        summary: "Send a message to the chat window. Use for: remote test AI behavior, send a message and see how AI responds. Don't use for: read chat history (use debug.dump_conversation), search web (use web.search). Example: user says '帮我测试一下，发个消息给 AI' → send chat message.",
        parameters: ["message": "Message text to send", "conversationTitle": "Optional: create new conversation with this title"], verified: true, category: "debug")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let message = params["message"] as? String, !message.isEmpty else {
            throw MCPError.invalidParams("message required")
        }
        guard let config = ModelStore.shared.defaultConfig else {
            throw MCPError.failed("no default model config")
        }
        // 异步发送，不阻塞工具调用
        DispatchQueue.main.async {
            ConversationStore.shared.send(message, using: config)
        }
        return [
            "sent": true,
            "message": message,
            "note": "Message sent. Use debug.dump_conversation to read AI's reply."
        ]
    }
}

/// v3.1.26：聊天工具——代替模型 API，直接回复消息
/// 用途：调试聊天界面 UI，不用真的调用云端模型
final class ChatReplyTool: MCPTool {
    let definition = ToolDefinition(
        name: "chat.reply",
        summary: "Simulate AI reply to chat. Use for: test chat UI without calling real model API. Don't use for: send user message (use chat.send), dump conversation (use debug.dump_conversation). Example: user says '帮我测试一下聊天界面，模拟 AI 回复' → chat.reply.",
        parameters: ["message": "AI reply text", "role": "Message role (assistant / tool / system, default: assistant)"], verified: true, category: "debug")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let message = params["message"] as? String, !message.isEmpty else {
            throw MCPError.invalidParams("message required")
        }
        let role = params["role"] as? String ?? "assistant"
        // 异步添加消息，不阻塞工具调用
        DispatchQueue.main.async {
            let msg = ChatMessage(role: role, content: message)
            ConversationStore.shared.appendToCurrent(msg)
        }
        return [
            "added": true,
            "role": role,
            "message": message,
            "note": "Reply added to chat. Use debug.dump_conversation to verify."
        ]
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
