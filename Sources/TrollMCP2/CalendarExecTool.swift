import Foundation
import EventKit

// MARK: - 日历大工具（合并 list / create 两个子命令）

final class CalendarExecTool: MCPTool {
    let definition = ToolDefinition(name: "calendar",
        summary: "Calendar operations (list upcoming events / create new event). Use for: check what meetings are coming up, schedule a new meeting/appointment. Don't use for: create reminder (use reminder.*), search contacts (use contacts.search). Example: user says '我这周有什么安排' → calendar list; user says '明天下午3点加个会议' → calendar create.",
        parameters: ["action": "Subcommand: 'list' or 'create'", "days": "For list: how many days ahead (default 7)", "title": "For create: event title", "start": "For create: start time (ISO8601)", "end": "For create: end time (optional, default +1 hour)", "notes": "For create: optional notes"], verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("action required: 'list' or 'create'")
        }

        switch action.lowercased() {
        case "list":
            return try listEvents(params)
        case "create":
            return try createEvent(params)
        default:
            throw MCPError.invalidParams("unknown action: \(action), use 'list' or 'create'")
        }
    }

    // 子命令：list
    private func listEvents(_ params: [String: Any]) throws -> [String: Any] {
        let days = params["days"] as? Int ?? 7
        let store = EKEventStore()
        let cal = Calendar.current
        let now = Date()
        let endOf = cal.date(byAdding: .day, value: days, to: now) ?? now

        let predicate = store.predicateForEvents(withStart: now, end: endOf, calendars: nil)
        let events = store.events(matching: predicate)
        return [
            "action": "list",
            "days": days,
            "events": events.map { [
                "title": $0.title ?? "",
                "start": ISO8601DateFormatter().string(from: $0.startDate),
                "end": ISO8601DateFormatter().string(from: $0.endDate)
            ]}
        ]
    }

    // 子命令：create
    private func createEvent(_ params: [String: Any]) throws -> [String: Any] {
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
                    result = ["action": "create", "created": false, "error": "日历未授权: \(err?.localizedDescription ?? "")"]
                    return
                }
                let ev = EKEvent(eventStore: store)
                ev.title = title
                ev.startDate = start
                ev.endDate = end
                ev.notes = params["notes"] as? String
                do {
                    try store.save(ev, span: .thisEvent, commit: true)
                    result = ["action": "create", "created": true, "title": title, "start": startStr,
                              "eventIdentifier": ev.eventIdentifier ?? ""]
                } catch {
                    result = ["action": "create", "created": false, "error": error.localizedDescription]
                }
            }
        }
        sem.wait()
        AuditLog.shared.log("calendar create", detail: title)
        return result
    }
}
