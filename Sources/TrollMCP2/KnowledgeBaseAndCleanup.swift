import Foundation
import SQLite3

// v2.9.72：崩溃知识库 + 工作区清理
// 1. FailureKnowledgeBase — 存储错误模式和修复方案，下次自动匹配
// 2. WorkspaceCleanupTool — 按天数/大小清理工作区临时文件

// MARK: - 崩溃知识库

final class FailureKnowledgeBase {
    static let shared = FailureKnowledgeBase()
    private var db: OpaquePointer?
    private let dbPath: String

    init() {
        let docs = NSHomeDirectory().appending("/Documents/Workspace")
        try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
        dbPath = docs.appending("/failure_kb.db")
        openDB()
        createTable()
        seedBuiltinPatterns()
    }

    private func openDB() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            db = nil
        }
    }

    private func createTable() {
        guard let db = db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS patterns (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword TEXT NOT NULL,
            category TEXT NOT NULL,
            cause TEXT NOT NULL,
            fix TEXT NOT NULL,
            hit_count INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_keyword ON patterns(keyword);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func seedBuiltinPatterns() {
        guard let db = db else { return }
        // 检查是否已有数据
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM patterns", -1, &stmt, nil)
        sqlite3_step(stmt)
        let count = sqlite3_column_int(stmt, 0)
        sqlite3_finalize(stmt)
        if count > 0 { return }

        let patterns: [(String, String, String, String)] = [
            ("Operation not permitted", "权限", "TrollStore 未开启「编辑 Entitlements」，侧载 App 没有 root 写入权限", "在 TrollStore 开启「编辑 Entitlements」后卸载重装（覆盖安装不会重新应用）"),
            ("bin-setuid=0", "权限", "注入工具没有 setuid root 位", "确认 TrollStore 已给 bin/ 工具打 setuid，卸载重装 App"),
            ("Failed to parse plist", "签名", "ldid 解析 entitlements plist 失败", "检查 entitlements 文件格式，或用 ct_bypass 重新签名"),
            ("link edit information does not fill", "Mach-O", "install_name_tool 无法处理 __LINKEDIT 段", "非阻断错误，ct_bypass 已完成签名，注入仍可成功"),
            ("Library not loaded", "依赖", "dylib 依赖的动态库不存在", "用 otool -L 检查依赖，确认所有依赖在目标设备上"),
            ("code signature invalid", "签名", "代码签名失效", "用 ldid -S 重新签名，或用 TrollStore 重装"),
            ("dyld: Symbol not found", "依赖", "dylib 引用了不存在的符号", "检查 dylib 编译时的 SDK 版本，确保与目标 iOS 兼容"),
            ("task_for_pid failed", "权限", "没有 task_for_pid-allow entitlement", "TrollStore 开启「编辑 Entitlements」后卸载重装"),
            ("cannot create regular file", "权限", "无法写入目标 App Bundle 目录", "确认目标 App 已关闭，root 权限生效"),
            ("Killed: 9", "崩溃", "App 被系统杀死（通常是签名或内存问题）", "检查崩溃日志，用 diagnose.crash 分析"),
            ("SSL/TLS connection failed", "网络", "GitHub 连接超时", "重试或配置代理，网络问题非 App bug"),
            ("unable to type-check", "编译", "Swift 表达式太复杂导致编译器超时", "拆分复杂字典/表达式为独立变量"),
            ("is inaccessible due to private", "编译", "访问了 private 成员", "将目标方法/属性改为 public 或 internal"),
            ("cannot find in scope", "编译", "符号未定义（通常缺少 import）", "添加缺失的 import 或检查拼写"),
        ]

        for (kw, cat, cause, fix) in patterns {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO patterns (keyword, category, cause, fix) VALUES (?,?,?,?)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, kw, -1, nil)
            sqlite3_bind_text(stmt, 2, cat, -1, nil)
            sqlite3_bind_text(stmt, 3, cause, -1, nil)
            sqlite3_bind_text(stmt, 4, fix, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func match(_ errorText: String) -> [(keyword: String, category: String, cause: String, fix: String)] {
        guard let db = db else { return [] }
        var results: [(String, String, String, String)] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT keyword, category, cause, fix FROM patterns ORDER BY hit_count DESC", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kw = String(cString: sqlite3_column_text(stmt, 0))
            if errorText.localizedCaseInsensitiveContains(kw) {
                let cat = String(cString: sqlite3_column_text(stmt, 1))
                let cause = String(cString: sqlite3_column_text(stmt, 2))
                let fix = String(cString: sqlite3_column_text(stmt, 3))
                results.append((kw, cat, cause, fix))
                // 递增命中计数
                incrementHit(kw)
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    private func incrementHit(_ keyword: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE patterns SET hit_count = hit_count + 1 WHERE keyword = ?", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, keyword, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func addPattern(keyword: String, category: String, cause: String, fix: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO patterns (keyword, category, cause, fix) VALUES (?,?,?,?)", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, keyword, -1, nil)
        sqlite3_bind_text(stmt, 2, category, -1, nil)
        sqlite3_bind_text(stmt, 3, cause, -1, nil)
        sqlite3_bind_text(stmt, 4, fix, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func allPatterns() -> [[String: Any]] {
        guard let db = db else { return [] }
        var results: [[String: Any]] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT keyword, category, cause, fix, hit_count FROM patterns ORDER BY hit_count DESC", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append([
                "keyword": String(cString: sqlite3_column_text(stmt, 0)),
                "category": String(cString: sqlite3_column_text(stmt, 1)),
                "cause": String(cString: sqlite3_column_text(stmt, 2)),
                "fix": String(cString: sqlite3_column_text(stmt, 3)),
                "hit_count": Int(sqlite3_column_int(stmt, 4))
            ])
        }
        sqlite3_finalize(stmt)
        return results
    }
}

// MARK: - 知识库查询工具

final class KnowledgeBaseTool: MCPTool {
    let definition = ToolDefinition(
        name: "kb.query",
        summary: "查询崩溃/错误知识库。输入错误信息，自动匹配已知模式并返回原因和修复方案。也可添加新模式。",
        parameters: [
            "error": "错误信息文本（必填，用于匹配）",
            "action": "query（默认查询）或 add（添加新模式）",
            "keyword": "add 时的关键词",
            "cause": "add 时的原因",
            "fix": "add 时的修复方案"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String) ?? "query"

        if action == "add" {
            guard let kw = params["keyword"] as? String,
                  let cause = params["cause"] as? String,
                  let fix = params["fix"] as? String else {
                throw MCPError.invalidParams("add requires keyword, cause, fix")
            }
            let category = params["category"] as? String ?? "自定义"
            FailureKnowledgeBase.shared.addPattern(keyword: kw, category: category, cause: cause, fix: fix)
            return ["added": true, "keyword": kw]
        }

        guard let error = params["error"] as? String, !error.isEmpty else {
            // 返回所有模式
            return ["patterns": FailureKnowledgeBase.shared.allPatterns()]
        }

        let matches = FailureKnowledgeBase.shared.match(error)
        return [
            "query": error,
            "matches": matches.map { ["keyword": $0.keyword, "category": $0.category, "cause": $0.cause, "fix": $0.fix] },
            "match_count": matches.count
        ]
    }
}

// MARK: - 工作区清理工具

final class WorkspaceCleanupTool: MCPTool {
    let definition = ToolDefinition(
        name: "workspace.cleanup",
        summary: "清理工作区临时文件：旧编译产物、下载缓存、日志、报告。按天数或大小过滤，支持 dry-run 预览。",
        parameters: [
            "dry_run": "仅预览不删除（默认 true）",
            "max_age_days": "删除超过 N 天的文件（默认 7）",
            "max_size_mb": "单个目录超过 N MB 时清理旧文件（默认 500）",
            "targets": "清理目标：downloads,logs,reports,all（默认 all）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let dryRun = (params["dry_run"] as? Bool) ?? true
        let maxAge = (params["max_age_days"] as? Int) ?? 7
        let maxSize = (params["max_size_mb"] as? Int) ?? 500
        let targets = (params["targets"] as? String) ?? "all"

        let workspace = NSHomeDirectory().appending("/Documents/Workspace")
        let cutoff = Date().addingTimeInterval(-TimeInterval(maxAge * 86400))
        var cleaned: [String: Int] = [:]
        var totalFreed: Int64 = 0

        let dirsToClean: [String]
        switch targets {
        case "downloads": dirsToClean = ["downloads"]
        case "logs": dirsToClean = ["logs"]
        case "reports": dirsToClean = ["reports"]
        default: dirsToClean = ["downloads", "logs", "reports", "network_capture"]
        }

        for dir in dirsToClean {
            let path = workspace.appending("/\(dir)")
            guard FileManager.default.fileExists(atPath: path) else { continue }

            var count = 0
            var freed: Int64 = 0
            if let files = try? FileManager.default.contentsOfDirectory(atPath: path) {
                for file in files {
                    let filePath = path.appending("/\(file)")
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                       let modDate = attrs[.modificationDate] as? Date,
                       let size = attrs[.size] as? Int64 {
                        if modDate < cutoff {
                            if !dryRun {
                                try? FileManager.default.removeItem(atPath: filePath)
                            }
                            count += 1
                            freed += size
                        }
                    }
                }
            }
            cleaned[dir] = count
            totalFreed += freed
        }

        // 检查工作区总大小
        var totalSize: Int64 = 0
        if let enumerator = FileManager.default.enumerator(atPath: workspace) {
            while let file = enumerator.nextObject() as? String {
                let filePath = workspace.appending("/\(file)")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                   let size = attrs[.size] as? Int64 {
                    totalSize += size
                }
            }
        }

        return [
            "dry_run": dryRun,
            "cleaned": cleaned,
            "freed_bytes": totalFreed,
            "freed_mb": String(format: "%.1f", Double(totalFreed) / 1024 / 1024),
            "workspace_total_mb": String(format: "%.1f", Double(totalSize) / 1024 / 1024),
            "hint": dryRun ? "dry-run 模式，未实际删除。设 dry_run=false 执行清理" : "已清理完成"
        ]
    }
}
