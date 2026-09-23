import Foundation
import UIKit
import CoreTelephony

// MARK: - 电话大工具（合并 call / schedule_call 两个子命令）

final class PhoneExecTool: MCPTool {
    let definition = ToolDefinition(name: "phone",
        summary: "Phone operations (call / schedule_call). Use subcommand to specify action. Use for: make a phone call, schedule a call reminder. Don't use for: send SMS (use messaging), contact lookup (use contacts.search). Example: user says '打电话给张三' → phone call; user says '5分钟后打电话给客户' → phone schedule_call.",
        parameters: ["action": "Subcommand: 'call' or 'schedule_call'", "number": "Phone number (e.g. 13800138000)", "delay_seconds": "Delay before call (for schedule_call, seconds)"], verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("action required: 'call' or 'schedule_call'")
        }

        switch action.lowercased() {
        case "call":
            return try makeCall(params)
        case "schedule_call":
            return try scheduleCall(params)
        default:
            throw MCPError.invalidParams("unknown action: \(action), use 'call' or 'schedule_call'")
        }
    }

    // 子命令：call（直接打电话）
    private func makeCall(_ params: [String: Any]) throws -> [String: Any] {
        guard let number = params["number"] as? String else { throw MCPError.invalidParams("number required") }
        guard let url = URL(string: "tel://\(number)") else {
            throw MCPError.invalidParams("invalid phone number: \(number)")
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        AuditLog.shared.log("phone call", detail: number)
        return ["action": "call", "called": true, "number": number]
    }

    // 子命令：schedule_call（定时提醒打电话）
    private func scheduleCall(_ params: [String: Any]) throws -> [String: Any] {
        guard let number = params["number"] as? String else { throw MCPError.invalidParams("number required") }
        let delay = max(params["delay_seconds"] as? Int ?? 60, 1)
        // 用本地通知提醒用户打电话
        let content = UNMutableNotificationContent()
        content.title = "打电话提醒"
        content.body = "现在打给 \(number)"
        content.sound = .default
        let id = UUID().uuidString
        let req = UNNotificationRequest(identifier: id,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        AuditLog.shared.log("phone schedule_call", detail: "\(number) +\(delay)s")
        return ["action": "schedule_call", "scheduled": true, "number": number, "fire_in_seconds": delay]
    }
}
