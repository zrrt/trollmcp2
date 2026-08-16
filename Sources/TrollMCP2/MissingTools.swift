import Foundation
import UIKit
import EventKit
import UserNotifications

// MARK: - 日历：创建事件

final class CalendarCreateEventTool: MCPTool {
    let definition = ToolDefinition(name: "calendar.create_event",
        summary: "在系统日历创建事件",
        parameters: ["title": "标题", "start": "开始时间 ISO8601", "end": "结束时间 ISO8601（可选，默认+1h）", "notes": "备注（可选）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        guard let startStr = params["start"] as? String,
              let start = ISO8601DateFormatter().date(from: startStr) else {
            throw MCPError.invalidParams("start 需为 ISO8601")
        }
        let end = (params["end"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? Calendar.current.date(byAdding: .hour, value: 1, to: start)!

        var result: [String: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let store = EKEventStore()
            store.requestAccess(to: .event) { granted, err in
                defer { sem.signal() }
                guard granted else {
                    result = ["created": false, "error": "日历未授权: \(err?.localizedDescription ?? "")"]
                    return
                }
                let ev = EKEvent(eventStore: store)
                ev.title = title
                ev.startDate = start
                ev.endDate = end
                ev.notes = params["notes"] as? String
                do {
                    try store.save(ev, span: .thisEvent, commit: true)
                    result = ["created": true, "title": title, "start": startStr,
                              "eventIdentifier": ev.eventIdentifier ?? ""]
                } catch {
                    result = ["created": false, "error": error.localizedDescription]
                }
            }
        }
        sem.wait()
        AuditLog.shared.log("calendar.create_event", detail: title)
        return result
    }
}

// MARK: - 提醒：定时提醒（真实本地通知）

final class ReminderScheduleTool: MCPTool {
    let definition = ToolDefinition(name: "reminder.schedule",
        summary: "在指定延迟后弹出本地提醒通知",
        parameters: ["title": "标题", "body": "内容", "delay_seconds": "多少秒后提醒"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
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
        AuditLog.shared.log("reminder.schedule", detail: "\(title) +\(delay)s")
        return ["scheduled": true, "id": id, "fire_in_seconds": delay]
    }
}

final class ReminderScheduleRecurringTool: MCPTool {
    let definition = ToolDefinition(name: "reminder.schedule_recurring",
        summary: "周期性弹出本地提醒通知",
        parameters: ["title": "标题", "body": "内容", "interval_seconds": "重复间隔秒数"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
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
        AuditLog.shared.log("reminder.schedule_recurring", detail: "\(title) every \(interval)s")
        return ["scheduled": true, "id": id, "interval_seconds": interval]
    }
}

// MARK: - 设备快照（电池/存储/系统）

final class DeviceSnapshotTool: MCPTool {
    let definition = ToolDefinition(name: "device.snapshot", summary: "采集设备当前状态（电量/存储/系统）")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryLevel
        let fm = FileManager.default
        var freeBytes: Int64 = 0
        if let url = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            freeBytes = Int64(vals?.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        return [
            "model": UIDevice.current.model,
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "batteryLevel": battery >= 0 ? String(format: "%.0f%%", battery * 100) : "unknown",
            "freeStorageBytes": freeBytes,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}

// MARK: - 网络搜索（Bing HTML 解析）

final class WebSearchTool: MCPTool {
    let definition = ToolDefinition(name: "web.search",
        summary: "用 Bing 检索并返回结果（标题/链接/摘要）",
        parameters: ["query": "搜索关键词", "limit": "返回条数（默认 8）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let query = params["query"] as? String, !query.isEmpty else {
            throw MCPError.invalidParams("query required")
        }
        let limit = params["limit"] as? Int ?? 8
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.bing.com/search?q=\(q)") else {
            throw MCPError.invalidParams("bad query")
        }
        var html: String = ""
        var fetchError: String?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let task = URLSession.shared.dataTask(with: url) { data, _, err in
                defer { sem.signal() }
                if let err = err { fetchError = err.localizedDescription; return }
                html = String(data: data ?? Data(), encoding: .utf8) ?? ""
            }
            task.resume()
        }
        sem.wait()
        if let e = fetchError { throw MCPError.failed("fetch failed: \(e)") }

        let results = parseBing(html: html, limit: limit)
        AuditLog.shared.log("web.search", detail: "\(query) → \(results.count)")
        return ["query": query, "count": results.count, "results": results]
    }

    private func parseBing(html: String, limit: Int) -> [[String: String]] {
        guard let regex = try? NSRegularExpression(pattern: "<li class=\"b_algo\">(.*?)</li>", options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [[String: String]] = []
        for m in matches.prefix(limit) {
            let block = ns.substring(with: m.range(at: 1))
            let head = block.firstMatch(pattern: "<h2><a[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a></h2>")
            let snippet = block.firstCapture(pattern: "<p[^>]*>([^<]{10,})</p>") ?? ""
            if let caps = head, caps.count == 2, !caps[1].isEmpty {
                out.append(["title": caps[1], "url": caps[0], "snippet": snippet])
            }
            if out.count >= limit { break }
        }
        return out
    }
}

extension String {
    /// 返回所有捕获组（不含整串）
    fileprivate func firstMatch(pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)) else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            groups.append((self as NSString).substring(with: m.range(at: i)))
        }
        return groups
    }

    /// 返回第一个捕获组
    fileprivate func firstCapture(pattern: String) -> String? {
        firstMatch(pattern: pattern)?.first
    }
}

// MARK: - 本机知识库（文件存储）

final class KnowledgeStore {
    static let shared = KnowledgeStore()
    var dir: URL { Workspace.root.appendingPathComponent("knowledge", isDirectory: true) }
    func ensure() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func list() -> [String] {
        ensure()
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }
}

final class KnowledgeImportTextTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.import_text",
        summary: "把文本导入本机知识库",
        parameters: ["name": "条目名", "content": "文本内容"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, let content = params["content"] as? String else {
            throw MCPError.invalidParams("name, content required")
        }
        KnowledgeStore.shared.ensure()
        let file = KnowledgeStore.shared.dir.appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        AuditLog.shared.log("knowledge.import_text", detail: name)
        return ["imported": true, "name": file.lastPathComponent, "bytes": content.utf8.count]
    }
}

final class KnowledgeImportFileTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.import_file",
        summary: "把工作区内文件导入知识库",
        parameters: ["path": "工作区内相对路径", "name": "条目名（可选）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else { throw MCPError.invalidParams("path required") }
        let src = try Workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: src.path) else { throw MCPError.failed("not found: \(path)") }
        KnowledgeStore.shared.ensure()
        let name = params["name"] as? String ?? src.lastPathComponent
        let dst = KnowledgeStore.shared.dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        AuditLog.shared.log("knowledge.import_file", detail: name)
        return ["imported": true, "name": name]
    }
}

final class KnowledgeSearchTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.search",
        summary: "在本机知识库检索",
        parameters: ["query": "关键词"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let query = params["query"] as? String, !query.isEmpty else { throw MCPError.invalidParams("query required") }
        KnowledgeStore.shared.ensure()
        var hits: [[String: Any]] = []
        for file in KnowledgeStore.shared.list() {
            let url = KnowledgeStore.shared.dir.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(query) {
                hits.append(["file": file, "line": i + 1, "snippet": line.trimmingCharacters(in: .whitespaces)])
                if hits.count >= 30 { break }
            }
        }
        AuditLog.shared.log("knowledge.search", detail: "\(query) → \(hits.count)")
        return ["query": query, "count": hits.count, "hits": hits]
    }
}

final class KnowledgeDeleteTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.delete", summary: "删除知识库条目",
        parameters: ["name": "条目名"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let file = KnowledgeStore.shared.dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw MCPError.failed("not found: \(name)") }
        try FileManager.default.removeItem(at: file)
        AuditLog.shared.log("knowledge.delete", detail: name)
        return ["deleted": true, "name": name]
    }
}

// MARK: - 电话

final class PhoneCallTool: MCPTool {
    let definition = ToolDefinition(name: "phone.call", summary: "打开系统拨号器拨号",
        parameters: ["number": "电话号码"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let number = params["number"] as? String, !number.isEmpty else { throw MCPError.invalidParams("number required") }
        let cleaned = number.components(separatedBy: CharacterSet(charactersIn: "+0123456789")).joined()
        guard let url = URL(string: "tel://" + cleaned), UIApplication.shared.canOpenURL(url) else {
            throw MCPError.failed("无法拨号: \(number)")
        }
        DispatchQueue.main.async { UIApplication.shared.open(url, options: [:]) }
        AuditLog.shared.log("phone.call", detail: number)
        return ["opened": true, "number": cleaned]
    }
}

final class PhoneScheduleCallTool: MCPTool {
    let definition = ToolDefinition(name: "phone.schedule_call",
        summary: "在延迟后弹出拨号提醒通知（需用户点击）",
        parameters: ["number": "电话号码", "display_name": "显示名（可选）", "delay_seconds": "延迟秒数"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let number = params["number"] as? String, !number.isEmpty else { throw MCPError.invalidParams("number required") }
        let delay = max(params["delay_seconds"] as? Int ?? 60, 1)
        let name = params["display_name"] as? String ?? number
        let content = UNMutableNotificationContent()
        content.title = "拨号提醒"
        content.body = "呼叫 \(name)（\(number)）"
        content.sound = .default
        let id = UUID().uuidString
        let req = UNNotificationRequest(identifier: id,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        AuditLog.shared.log("phone.schedule_call", detail: "\(name) +\(delay)s")
        return ["scheduled": true, "id": id, "number": number, "requiresUserTap": true]
    }
}

// MARK: - 技能开关

final class SkillsSetEnabledTool: MCPTool {
    let definition = ToolDefinition(name: "skills.set_enabled",
        summary: "启用/停用某个技能",
        parameters: ["name": "技能名", "enabled": "true/false"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let enabled = params["enabled"] as? Bool ?? true
        var dict = UserDefaults.standard.object(forKey: "trollmcp2.skills_enabled") as? [String: Bool] ?? [:]
        dict[name] = enabled
        UserDefaults.standard.set(dict, forKey: "trollmcp2.skills_enabled")
        AuditLog.shared.log("skills.set_enabled", detail: "\(name) \(enabled)")
        return ["name": name, "enabled": enabled]
    }
}
