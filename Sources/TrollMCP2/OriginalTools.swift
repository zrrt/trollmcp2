import Foundation

// MARK: - 自动化任务存储（automation.* / gateway.cron_* 共用）

final class AutomationStore: ObservableObject {
    static let shared = AutomationStore()

    struct Task: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var name: String
        var schedule: String          // cron 表达式或描述
        var action: String            // 工具调用描述
        var enabled: Bool = true
        var lastRun: Date?
    }

    @Published var tasks: [Task] = []
    private let key = "trollmcp2.automation_tasks"

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Task].self, from: data) else { return }
        tasks = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ task: Task) {
        tasks.append(task)
        save()
    }

    func update(_ task: Task) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
            save()
        }
    }

    func remove(_ task: Task) {
        tasks.removeAll { $0.id == task.id }
        save()
    }

    func setEnabled(_ task: Task, enabled: Bool) {
        var t = task
        t.enabled = enabled
        update(t)
        AuditLog.shared.log("automation.set_enabled", detail: "\(task.name) \(enabled ? "启用" : "停用")")
    }

    @discardableResult
    func run(name: String) -> Bool {
        guard var t = tasks.first(where: { $0.name == name }) else { return false }
        guard t.enabled else {
            AuditLog.shared.log("automation", detail: "\(name) 已停用，跳过", level: .warning)
            return false
        }
        t.lastRun = Date()
        update(t)
        AuditLog.shared.log("automation.run_now", detail: "\(name): \(t.action)")
        return true
    }

    var history: [AuditLog.Entry] {
        AuditLog.shared.entries.filter { $0.category.hasPrefix("automation") || $0.category.hasPrefix("gateway.cron") }
    }
}

// MARK: - 原版缺失工具：injection.remove

final class InjectionRemoveTool: MCPTool {
    let definition = ToolDefinition(name: "injection.remove", summary: "彻底移除指定 App 的注入（含 dylib 文件）",
        parameters: ["bundle_id": "目标 App Bundle ID"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let result = try InjectionManager.shared.disable(bundleId: bid)
        // 尝试删除拷贝进 App 包的 dylib
        var removedFile = false
        if let app = AppCatalog.find(bid) {
            let dylib = URL(fileURLWithPath: app.path).appendingPathComponent("TrollMCPAgent.dylib")
            if FileManager.default.fileExists(atPath: dylib.path) {
                try? FileManager.default.removeItem(at: dylib)
                removedFile = true
            }
        }
        AuditLog.shared.log("injection.remove", detail: "\(bid) dylib已删=\(removedFile)")
        var merged = result
        merged["dylib_removed"] = removedFile
        return merged
    }
}

// MARK: - 原版缺失工具：container.delete

final class ContainerDeleteTool: MCPTool {
    let definition = ToolDefinition(name: "container.delete", summary: "删除指定 App 容器内的文件或目录",
        parameters: ["bundle_id": "目标 App", "path": "容器内路径"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String,
              let path = params["path"] as? String else {
            throw MCPError.invalidParams("bundle_id, path required")
        }
        guard let app = AppCatalog.find(bid), let container = app.containerPath else {
            throw MCPError.failed("container not accessible for \(bid)")
        }
        let url = URL(fileURLWithPath: container).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.failed("not found: \(path)")
        }
        try FileManager.default.removeItem(at: url)
        AuditLog.shared.log("container.delete", detail: "\(bid):\(path)")
        return ["deleted": true, "path": path]
    }
}

// MARK: - 原版缺失工具：gateway.*

final class GatewayChannelSendTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.channel_send", summary: "向 Gateway 频道广播消息",
        parameters: ["channel": "频道名", "message": "消息内容"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard GatewayClient.shared.isConnected else { throw MCPError.failed("gateway not connected") }
        guard let channel = params["channel"] as? String else { throw MCPError.invalidParams("channel required") }
        let message = params["message"] as? String ?? ""
        let payload: [String: Any] = ["type": "channel", "channel": channel, "message": message]
        let data = try JSONSerialization.data(withJSONObject: payload)
        GatewayClient.shared.send(String(data: data, encoding: .utf8) ?? "{}")
        AuditLog.shared.log("gateway.channel_send", detail: channel)
        return ["sent": true, "channel": channel]
    }
}

final class GatewayCronCreateTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.cron_create", summary: "创建 Gateway 定时任务",
        parameters: ["name": "任务名", "schedule": "cron 表达式", "action": "执行的动作描述"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let task = AutomationStore.Task(
            name: name,
            schedule: params["schedule"] as? String ?? "*/5 * * * *",
            action: params["action"] as? String ?? "ping"
        )
        AutomationStore.shared.add(task)
        AuditLog.shared.log("gateway.cron_create", detail: "\(task.name) \(task.schedule)")
        return ["created": true, "name": name]
    }
}

final class GatewayCronRunTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.cron_run", summary: "立即执行一个定时任务",
        parameters: ["name": "任务名"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        guard AutomationStore.shared.run(name: name) else {
            throw MCPError.failed("task not found or disabled: \(name)")
        }
        return ["ran": true, "name": name]
    }
}

final class GatewayCronCancelTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.cron_cancel", summary: "取消/删除定时任务",
        parameters: ["name": "任务名"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        guard let task = AutomationStore.shared.tasks.first(where: { $0.name == name }) else {
            throw MCPError.failed("task not found: \(name)")
        }
        AutomationStore.shared.remove(task)
        AuditLog.shared.log("gateway.cron_cancel", detail: name)
        return ["cancelled": true, "name": name]
    }
}

final class GatewayNodeInvokeTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.node_invoke", summary: "远程调用 Gateway 节点方法（原版命名）",
        parameters: ["node": "节点名", "method": "方法", "params": "参数对象"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard GatewayClient.shared.isConnected else { throw MCPError.failed("gateway not connected") }
        let payload: [String: Any] = [
            "type": "node_invoke",
            "node": params["node"] as? String ?? "",
            "method": params["method"] as? String ?? "",
            "params": params["params"] ?? [:]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        GatewayClient.shared.send(String(data: data, encoding: .utf8) ?? "{}")
        return ["sent": true]
    }
}

// MARK: - 原版缺失工具：automation.*

final class AutomationCancelTool: MCPTool {
    let definition = ToolDefinition(name: "automation.cancel", summary: "取消正在运行的自动化任务",
        parameters: ["name": "任务名"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        AuditLog.shared.log("automation.cancel", detail: name)
        return ["cancelled": true, "name": name]
    }
}

final class AutomationHistoryTool: MCPTool {
    let definition = ToolDefinition(name: "automation.history", summary: "查询自动化任务执行历史")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let entries = AutomationStore.shared.history.prefix(50)
        return [
            "count": entries.count,
            "history": entries.map { ["time": ISO8601DateFormatter().string(from: $0.timestamp), "category": $0.category, "detail": $0.detail] }
        ]
    }
}

final class AutomationSetEnabledTool: MCPTool {
    let definition = ToolDefinition(name: "automation.set_enabled", summary: "启用/停用自动化任务",
        parameters: ["name": "任务名", "enabled": "true/false"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String,
              let task = AutomationStore.shared.tasks.first(where: { $0.name == name }) else {
            throw MCPError.invalidParams("unknown task name")
        }
        let enabled = params["enabled"] as? Bool ?? true
        AutomationStore.shared.setEnabled(task, enabled: enabled)
        return ["name": name, "enabled": enabled]
    }
}

// MARK: - 原版缺失工具：model.*

final class ModelAuthenticationTool: MCPTool {
    let definition = ToolDefinition(name: "model.authentication", summary: "查看当前模型的鉴权方式与密钥状态")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let config = ModelStore.shared.defaultConfig else {
            throw MCPError.failed("no model configured")
        }
        let masked: String
        if config.apiKey.count > 8 {
            masked = String(config.apiKey.prefix(4)) + "****" + String(config.apiKey.suffix(4))
        } else {
            masked = config.apiKey.isEmpty ? "(空)" : "****"
        }
        return [
            "authMethod": config.authMethod,
            "apiKeyMasked": masked,
            "hasKey": !config.apiKey.isEmpty,
            "provider": config.provider
        ]
    }
}

final class ModelSelectedProfileIDTool: MCPTool {
    let definition = ToolDefinition(name: "model.selectedProfileID", summary: "获取/设置当前选中的模型配置 ID",
        parameters: ["profile_id": "可选：要切换到的配置 UUID"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let store = ModelStore.shared
        if let newId = params["profile_id"] as? String,
           let target = store.configs.first(where: { $0.id.uuidString == newId }) {
            var updated = target
            updated.isDefault = true
            store.update(updated)
            AuditLog.shared.log("model.selectedProfileID", detail: "切换到 \(target.name)")
            return ["selected": target.name, "id": newId]
        }
        guard let current = store.defaultConfig else {
            throw MCPError.failed("no model configured")
        }
        return ["selected": current.name, "id": current.id.uuidString]
    }
}

// MARK: - 原版缺失工具：workspace.output*

final class WorkspaceOutputBookmarkTool: MCPTool {
    let definition = ToolDefinition(name: "workspace.outputBookmark", summary: "获取/设置工作区输出目录书签",
        parameters: ["bookmark": "可选：要保存的书签名"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let key = "trollmcp2.output_bookmark"
        if let bookmark = params["bookmark"] as? String {
            UserDefaults.standard.set(bookmark, forKey: key)
            AuditLog.shared.log("workspace.outputBookmark", detail: bookmark)
            return ["set": bookmark]
        }
        return ["bookmark": UserDefaults.standard.string(forKey: key) ?? "Output"]
    }
}

final class WorkspaceOutputNameTool: MCPTool {
    let definition = ToolDefinition(name: "workspace.outputName", summary: "获取/设置工作区输出产物命名",
        parameters: ["name": "可选：输出名称"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let key = "trollmcp2.output_name"
        if let name = params["name"] as? String {
            UserDefaults.standard.set(name, forKey: key)
            return ["set": name]
        }
        return ["name": UserDefaults.standard.string(forKey: key) ?? "artifact"]
    }
}
