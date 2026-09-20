import Foundation
import UserNotifications

// MARK: - 自动化任务存储（automation.* / gateway.cron_* 共用）

final class AutomationStore: ObservableObject {
    static let shared = AutomationStore()
    let center = UNUserNotificationCenter.current()

    struct Task: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var name: String
        var schedule: String = ""       // cron 表达式或描述
        var action: String = ""         // 动作描述
        var kind: String = "reminder"   // reminder | call | cron
        var title: String = ""
        var body: String = ""
        var number: String = ""
        var delay: Int = 0
        var interval: Int = 0
        var enabled: Bool = true
        var lastRun: Date?
        var createdAt: Date = Date()
    }

    @Published var tasks: [Task] = []
    private let key = "trollmcp2.automation_tasks"

    init() { load(); requestAuth() }

    func requestAuth() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

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
        schedule(task)
    }

    func update(_ task: Task) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
        }
        save()
        schedule(task)
    }

    func remove(_ task: Task) {
        tasks.removeAll { $0.id == task.id }
        save()
        cancel(task)
    }

    func setEnabled(_ task: Task, enabled: Bool) {
        var t = task
        t.enabled = enabled
        update(t)
        AuditLog.shared.log("automation.set_enabled", detail: "\(task.name) \(enabled ? "启用" : "停用")")
    }

    // MARK: - 真实调度

    private func trigger(for task: Task) -> UNNotificationTrigger? {
        if task.kind == "cron", task.interval > 0 {
            return UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(task.interval), repeats: true)
        }
        let secs = max(TimeInterval(task.delay), 1)
        return UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
    }

    private func schedule(_ task: Task) {
        guard task.enabled else { cancel(task); return }
        let content = UNMutableNotificationContent()
        switch task.kind {
        case "call":
            content.title = "来电提醒"
            content.body = task.number.isEmpty ? (task.body.isEmpty ? task.name : task.body) : "呼叫 \(task.number)"
        default:
            content.title = task.title.isEmpty ? (task.action.isEmpty ? task.name : task.action) : task.title
            content.body = task.body.isEmpty ? task.action : task.body
        }
        content.sound = .default
        content.userInfo = ["automationId": task.id.uuidString, "kind": task.kind]
        let req = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger(for: task))
        center.add(req) { err in
            if let err = err {
                AuditLog.shared.log("automation", detail: "调度失败: \(err.localizedDescription)", level: .warning)
            }
        }
        AuditLog.shared.log("automation.schedule", detail: "\(task.name) kind=\(task.kind)")
    }

    private func cancel(_ task: Task) {
        center.removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
    }

    @discardableResult
    func run(name: String) -> Bool {
        guard var t = tasks.first(where: { $0.name == name }) else { return false }
        guard t.enabled else {
            AuditLog.shared.log("automation", detail: "\(name) 已停用，跳过", level: .warning)
            return false
        }
        let content = UNMutableNotificationContent()
        switch t.kind {
        case "call":
            content.title = "来电提醒"
            content.body = t.number.isEmpty ? t.name : "呼叫 \(t.number)"
        default:
            content.title = t.title.isEmpty ? (t.action.isEmpty ? t.name : t.action) : t.title
            content.body = t.body.isEmpty ? t.action : t.body
        }
        content.sound = .default
        content.userInfo = ["automationId": t.id.uuidString, "kind": t.kind, "manual": true]
        let req = UNNotificationRequest(identifier: t.id.uuidString + "-run-" + UUID().uuidString,
                                        content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
        t.lastRun = Date()
        update(t)
        AuditLog.shared.log("automation.run_now", detail: name)
        return true
    }

    /// 取消指定通知请求（automation.cancel）
    func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    var history: [AuditLog.Entry] {
        AuditLog.shared.entries.filter { $0.category.hasPrefix("automation") || $0.category.hasPrefix("gateway.cron") }
    }
}

/// 从 cron 表达式 "*/N * * * *" 解析秒间隔（其余返回 nil）
func cronSeconds(_ expr: String) -> Int? {
    let parts = expr.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
    guard parts.count == 5 else { return nil }
    if parts[0].hasPrefix("*/") {
        return Int(parts[0].dropFirst(2)).map { $0 * 60 }
    }
    if let m = Int(parts[0]) { return m * 60 }
    return nil
}

// MARK: - 原版缺失工具：injection.remove

final class InjectionRemoveTool: MCPTool {
    let definition = ToolDefinition(name: "injection.remove", summary: "Completely remove injection from an app (including dylib files)",
        parameters: ["bundle_id": "Target App bundle_id (REQUIRED)"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let result = try InjectionManager.shared.disable(bundleId: bid)
        // 尝试删除拷贝进 App 包的 dylib
        var removedFile = false
        if let app = AppCatalog.find(bid) {
            let dylib = URL(fileURLWithPath: app.path).appendingPathComponent("ControlAgent.dylib")
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
    let definition = ToolDefinition(name: "container.delete", summary: "Delete a file or directory inside an app container",
        parameters: ["bundle_id": "Target App (REQUIRED)", "path": "Path inside container (REQUIRED)"], verified: true, category: "filesystem")
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
    let definition = ToolDefinition(name: "gateway.channel_send", summary: "Broadcast a message to a Gateway channel",
        parameters: ["channel": "Channel name (REQUIRED)", "message": "Message content (optional)"], verified: true, category: "automation")
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
    let definition = ToolDefinition(name: "gateway.cron_create", summary: "Create a Gateway scheduled task (real local notification scheduling)",
        parameters: ["name": "Task name (REQUIRED)", "schedule": "cron expression (optional)", "action": "Action description (optional)"], verified: true, category: "automation")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let schedule = params["schedule"] as? String ?? "*/5 * * * *"
        let task = AutomationStore.Task(
            name: name,
            schedule: schedule,
            action: params["action"] as? String ?? "ping",
            kind: "cron",
            interval: cronSeconds(schedule) ?? 300
        )
        AutomationStore.shared.add(task)
        AuditLog.shared.log("gateway.cron_create", detail: "\(task.name) \(task.schedule)")
        return ["created": true, "name": name, "interval": task.interval]
    }
}

final class GatewayCronRunTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.cron_run", summary: "Immediately run a scheduled task",
        parameters: ["name": "Task name (REQUIRED)"], verified: true, category: "automation")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        guard AutomationStore.shared.run(name: name) else {
            throw MCPError.failed("task not found or disabled: \(name)")
        }
        return ["ran": true, "name": name]
    }
}

final class GatewayCronCancelTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.cron_cancel", summary: "Cancel or delete a scheduled task",
        parameters: ["name": "Task name (REQUIRED)"], verified: true, category: "automation")
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
    let definition = Toolname: "gateway.node_invoke", summary: "Remote-invoke a Gateway node method (original naming)",
        parameters: ["node": "Node name (optional)", "method": "Method (optional)", "params": "Params object (REQUIRED)"]ms object"], verified: true, category: "automation")
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
    let definition = ToolDefinition(name: "automation.cancel", summary: "Cancel scheduled automation. Use for: stop task.",
        parameters: ["name": "Task name or id (REQUIRED)"], verified: true, category: "device")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let store = AutomationStore.shared
        guard let task = store.tasks.first(where: { $0.name == name || $0.id.uuidString == name }) else {
            throw MCPError.failed("task not found: \(name)")
        }
        store.remove(task)
        AuditLog.shared.log("automation.cancel", detail: name)
        return ["cancelled": true, "name": name]
    }
}

final class AutomationHistoryTool: MCPTool {
    let defininame: "automation.history", summary: "Show automation execution history. Use for: review past runs.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let entries = AutomationStore.shared.history.prefix(50)
        return [
            "count": entries.count,
            "history": entries.map { ["time": ISO8601DateFormatter().string(from: $0.timestamp), "category": $0.category, "detail": $0.detail] }
        ]
    }
}

final class AutomationSetEnabledTool: MCPTool {
    let definition = ToolDefinition(name: "automation.set_enabled", summary: "Enable/disable automation. Use for: toggle task.",
        parameters: ["name": "Task name (REQUIRED)", "enabled": "true/false (optional)"]nabled": "true/false"], verified: true)
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
    let definition = ToolDefinition(name: "model.authentication", summary: "Check current model auth method and key status")
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
    let definition = ToolDefinition(name: "model.selectedProfileID", summary: "Get or set current selected model profile ID",
        parameters: ["profile_id": "Optional: profile UUID to switch to"], verified: true, category: "system")
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
    let definition = ToolDefinition(name: "workspace.outputBookmark", summary: "Get or set workspace output directory bookmark",
        parameters: ["bookmark": "Optional: bookmark name to save"], verified: true)
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
    let definition = ToolDefinition(name: "workspace.outputName", summary: "Get or set workspace output artifact naming",
        parameters: ["name": "Optional: output name"], verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let key = "trollmcp2.output_name"
        if let name = params["name"] as? String {
            UserDefaults.standard.set(name, forKey: key)
            return ["set": name]
        }
        return ["name": UserDefaults.standard.string(forKey: key) ?? "artifact"]
    }
}
