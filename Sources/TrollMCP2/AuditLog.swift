import Foundation
import Combine

/// 审计日志：记录所有 MCP 工具调用与系统事件
/// v2.9.126：内存 500 条 + 文件日志按天滚动（保留 7 天，对齐 TrollFools DDFileLogger 轮转）
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

    private let logQueue = DispatchQueue(label: "trollagent.auditlog.file")
    private let logsDir: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private let retentionDays = 7

    init() {
        pruneOldLogs()
    }

    func log(_ category: String, detail: String, level: Entry.Level = .info) {
        DispatchQueue.main.async {
            self.entries.insert(Entry(category: category, detail: detail, level: level), at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast()
            }
        }
        fileAppend("[\(category)] \(detail)")
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
        fileAppend("[\(category)] \(status.rawValue) \(elapsedMs)ms \(dataBytes)B perm=\(permission) \(detail)")
    }

    /// v2.9.126：文件日志——按天滚动（audit-YYYYMMDD.log），异步追加，防阻塞主线程
    private func fileAppend(_ line: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "yyyyMMdd"
            let file = self.logsDir.appendingPathComponent("audit-\(dayFmt.string(from: Date())).log")
            let stamp = formatter.string(from: Date())
            guard let data = ("\(stamp) \(line)\n").data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: file.path) {
                if let handle = try? FileHandle(forWritingTo: file) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: file)
            }
        }
    }

    /// 保留最近 7 天日志文件（对齐 TrollFools 7 天滚动），启动时清理
    private func pruneOldLogs() {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let cutoff = Date().addingTimeInterval(-Double(self.retentionDays) * 86400)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: self.logsDir.path)) ?? []
            for name in files where name.hasPrefix("audit-") {
                let full = self.logsDir.appendingPathComponent(name)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: full.path),
                   let mtime = attrs[.modificationDate] as? Date, mtime < cutoff {
                    try? FileManager.default.removeItem(at: full)
                }
            }
        }
    }

    func clear() {
        entries.removeAll()
    }
}
