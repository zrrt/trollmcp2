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

        enum Level: String, Codable {
            case info, warning, error
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

    func clear() {
        entries.removeAll()
    }
}
