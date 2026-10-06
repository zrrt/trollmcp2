import Foundation
import EventKit
import UserNotifications

// MARK: - 提醒事项大工具 (合并 create / schedule / recurring 三个子命令）

final class ReminderExecTool: MCPTool {
    let definition = ToolDefinition(name: "reminder",
        summary: "提醒事项/本地通知. action: create(写进iPhone提醒App, params:title/notes) / schedule(一次性通知, params:title/body/delay_seconds) / recurring(重复通知, params:title/body/interval_seconds). Use for: 待办、延时提醒、周期闹钟. 定时自动化任务走 automation.cron_fire.",
        parameters: ["action": "Subcommand: 'create' / 'schedule' / 'recurring'", "title": "Reminder title", "notes": "For create: optional notes", "body": "For schedule/recurring: notification message", "delay_seconds": "For schedule: delay in seconds", "interval_seconds": "For recurring: repeat interval in seconds"], verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("action required: 'create' / 'schedule' / 'recurring'")
        }

        switch action.lowercased() {
        case "create":
            return try createReminder(params)
        case "schedule":
            return try scheduleReminder(params)
        case "recurring":
            return try recurringReminder(params)
        default:
            throw MCPError.invalidParams("unknown action: \(action), use 'create' / 'schedule' / 'recurring'")
        }
    }

    // 子命令：create (在 iPhone 提醒事项 App 里创建）
    private func createReminder(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = params["notes"] as? String
        try store.save(reminder, commit: true)
        AuditLog.shared.log("reminder create", detail: title)
        return ["action": "create", "created": true, "title": title]
    }

    // 子命令：schedule (一次性本地通知）
    private func scheduleReminder(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        let delay = max(params["delay_seconds"] as? Int ?? 60, 1)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = params["body"] as? String ?? ""
        content.sound = .default
        let id = UUID().uuidString
        let req = UNNotificationRequest(identifier: id,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        AuditLog.shared.log("reminder schedule", detail: "\(title) +\(delay)s")
        return ["action": "schedule", "scheduled": true, "id": id, "fire_in_seconds": delay]
    }

    // 子命令：recurring (重复本地通知）
    private func recurringReminder(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        let interval = max(params["interval_seconds"] as? Int ?? 3600, 1)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = params["body"] as? String ?? ""
        content.sound = .default
        let id = UUID().uuidString
        let req = UNNotificationRequest(identifier: id,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(interval), repeats: true))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        AuditLog.shared.log("reminder recurring", detail: "\(title) every \(interval)s")
        return ["action": "recurring", "scheduled": true, "id": id, "interval_seconds": interval]
    }
}
