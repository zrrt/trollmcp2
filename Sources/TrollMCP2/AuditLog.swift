import Foundation
import Combine

/// 审计日志：记录所有 MCP 工具调用与系统事件
final class AuditLog: ObservableObject {
    static let shared = AuditLog()

    struct Entry: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var timestamp: Date = Date()
        var category: String
        var detail: String
        var level: Level = .info
        // v2.9.36：老 MCP 审计字段（执行状态/耗时/数据量/权限类型）
        var status: EntryStatus? = nil
        var elapsedMs: Int? = nil
        var dataBytes: Int? = nil
        var permission: String? = nil

        enum Level: String, Codable {
            case info, warning, error
        }

        enum EntryStatus: String, Codable {
            case success, failure
        }
    }

    @Published var entries: [Entry] = []
    private let maxEntries = 500

    func log(_ category: String, detail: String, level: Entry.Level = .info) {
        DispatchQueue.main.async {
            self.entries.insert(Entry(category: category, detail: detail, level: level), at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast()
            }
        }
    }

    // v2.9.36：工具调用统一审计（在 ToolRegistry.dispatch 入口记录）
    func logTool(_ category: String, status: Entry.EntryStatus, elapsedMs: Int, dataBytes: Int, permission: String, detail: String = "") {
        DispatchQueue.main.async {
            self.entries.insert(Entry(category: category, detail: detail,
                                      status: status, elapsedMs: elapsedMs,
                                      dataBytes: dataBytes, permission: permission), at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast()
            }
        }
    }

    func clear() {
        entries.removeAll()
    }
}
