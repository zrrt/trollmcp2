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
        // v2.9.128：CLI 错误四分类（env/target/param/tool）——让用户和 AI 都能看到"为什么失败"
        var errorCode: String? = nil
        var errorReason: String? = nil
        var nextStep: String? = nil

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
    // v2.9.128：新增 code/reason/nextStep——失败时记录 CLI 四分类，供健康度聚合与 AI 自查
    func logTool(_ category: String, status: Entry.EntryStatus, elapsedMs: Int, dataBytes: Int,
                 permission: String, detail: String = "",
                 code: String? = nil, reason: String? = nil, nextStep: String? = nil) {
        DispatchQueue.main.async {
            self.entries.insert(Entry(category: category, detail: detail,
                                      status: status, elapsedMs: elapsedMs,
                                      dataBytes: dataBytes, permission: permission,
                                      errorCode: code, errorReason: reason, nextStep: nextStep), at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast()
            }
        }
        let codeTag = code.map { " code=\($0)" } ?? ""
        fileAppend("[\(category)] \(status.rawValue) \(elapsedMs)ms \(dataBytes)B perm=\(permission)\(codeTag) \(detail)")
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

    // MARK: - v2.9.128 工具健康度聚合（从内存 entries 现算）

    struct ToolHealth: Identifiable {
        var id: String { tool }
        let tool: String
        let success: Int
        let failure: Int
        let avgMs: Int
        let topCode: String
        let lastFailureDetail: String
        var failureRate: Double { failure == 0 ? 0 : Double(failure) / Double(failure + success) }
    }

    struct CodeDist: Identifiable {
        var id: String { code }
        let code: String
        let count: Int
    }

    /// 按工具聚合健康度：失败数排序 → 一眼看出"哪些工具有问题"
    func healthSummary(limit: Int = 30) -> [ToolHealth] {
        var map: [String: (s: Int, f: Int, ms: [Int], code: [String: Int], lastFail: String)] = [:]
        for e in entries where e.status != nil {
            let k = e.category
            var v = map[k] ?? (s: 0, f: 0, ms: [Int](), code: [String: Int](), lastFail: "")
            if e.status == .success { v.s += 1 }
            else {
                v.f += 1
                let c = e.errorCode ?? "unknown"
                v.code[c, default: 0] += 1
                v.lastFail = e.errorReason ?? e.detail
            }
            if let ms = e.elapsedMs { v.ms.append(ms) }
            map[k] = v
        }
        let ranked = map
            .map { (tool: $0.key, v: $0.value) }
            .filter { $0.v.f > 0 || $0.v.s > 0 }
            .sorted { $0.v.f != $1.v.f ? $0.v.f > $1.v.f : $0.tool < $1.tool }
            .prefix(limit)
        var out: [ToolHealth] = []
        for item in ranked {
            let avg = item.v.ms.isEmpty ? 0 : item.v.ms.reduce(0, +) / item.v.ms.count
            let topCode = item.v.code.max { $0.value < $1.value }?.key ?? "ok"
            out.append(ToolHealth(tool: item.tool, success: item.v.s, failure: item.v.f,
                                  avgMs: avg, topCode: topCode,
                                  lastFailureDetail: String(item.v.lastFail.prefix(160))))
        }
        return out
    }

    /// 错误码分布（env/target/param/tool + unknown）
    func codeDistribution() -> [CodeDist] {
        var map: [String: Int] = [:]
        for e in entries where e.status == .failure {
            let c = e.errorCode ?? "unknown"
            map[c, default: 0] += 1
        }
        return map.map { CodeDist(code: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// 最近失败明细（供审计页/AI 自查）
    func recentFailures(limit: Int = 20) -> [Entry] {
        entries.filter { $0.status == .failure }.prefix(limit).map { $0 }
    }
}
