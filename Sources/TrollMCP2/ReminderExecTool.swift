import Foundation
import EventKit
import UserNotifications

// MARK: - 提醒事项大工具（合并 create / schedule / recurring 三个子命令）

final class ReminderExecTool: MCPTool {
    let definition = ToolDefinition(name: "reminder",
        summary: "Reminder operations (create todo / schedule one-time notification / schedule recurring notification). Use for: set a to-do item, get reminded after a delay, periodic alerts. Don't use for: list upcoming calendar events (use calendar), send immediate notification (use notification.send). Example: user says '提醒我明天开会' → reminder create; user says '10分钟后提醒我喝水' → reminder schedule; user says '每小时提醒我喝水' → reminder recurring.",
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

    // 子命令：create（在 iPhone 提醒事项 App 里创建）
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

    // 子命令：schedule（一次性本地通知）
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

    // 子命令：recurring（重复本地通知）
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
