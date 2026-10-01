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

    private func insertPattern(_ kw: String, _ cat: String, _ cause: String, _ fix: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO patterns (keyword, category, cause, fix) VALUES (?,?,?,?)", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, kw, -1, nil)
        sqlite3_bind_text(stmt, 2, cat, -1, nil)
        sqlite3_bind_text(stmt, 3, cause, -1, nil)
        sqlite3_bind_text(stmt, 4, fix, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func keywordExists(_ kw: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT 1 FROM patterns WHERE keyword=? LIMIT 1", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, kw, -1, nil)
        let found = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        return found
    }

    // v1 种子（15 条，仅空库时插入）
    private let v1Patterns: [(String, String, String, String)] = [
        ("Operation not permitted", "权限", "TrollStore 未开启「编辑 Entitlements」，侧载 App 没有 root 写入权限", "在 TrollStore 开启「编辑 Entitlements」后卸载重装 (覆盖安装不会重新应用)"),
        ("bin-setuid=0", "权限", "注入工具没有 setuid root 位", "确认 TrollStore 已给 bin/ 工具打 setuid，卸载重装 App"),
        ("Failed to parse plist", "签名", "ldid 解析 entitlements plist failed", "检查 entitlements 文件格式，或用 ct_bypass 重新签名"),
        ("link edit information does not fill", "Mach-O", "install_name_tool 无法处理 __LINKEDIT 段", "非阻断错误，ct_bypass 已done签名，注入仍可OK"),
        ("Library not loaded", "依赖", "dylib 依赖的动态库不存在", "用 otool -L 检查依赖，确认所有依赖在目标设备上"),
        ("code signature invalid", "签名", "代码签名失效", "用 ldid -S 重新签名，或用 TrollStore 重装"),
        ("dyld: Symbol not found", "依赖", "dylib 引用了不存在的符号", "检查 dylib 编译时的 SDK 版本，确保与目标 iOS 兼容"),
        ("task_for_pid failed", "权限", "没有 task_for_pid-allow entitlement", "TrollStore 开启「编辑 Entitlements」后卸载重装"),
        ("cannot create regular file", "权限", "无法写入目标 App Bundle 目录", "确认目标 App 已关闭，root 权限生效"),
        ("Killed: 9", "崩溃", "App 被系统杀死 (通常是签名或内存问题)", "检查崩溃日志，用 diagnose.crash 分析"),
        ("SSL/TLS connection failed", "网络", "GitHub 连接超时", "重试或配置代理，网络问题非 App bug"),
        ("unable to type-check", "编译", "Swift 表达式太复杂导致编译器超时", "拆分复杂字典/表达式为独立变量"),
        ("is inaccessible due to private", "编译", "访问了 private 成员", "将目标方法/属性改为 public 或 internal"),
        ("cannot find in scope", "编译", "符号未定义 (通常缺少 import)", "添加缺失的 import 或检查拼写"),
    ]

    // v2 种子（v4.3.66 追加，覆盖游戏/注入/系统崩溃/环境）
    private let v2Patterns: [(String, String, String, String)] = [
        ("Image not found", "依赖", "dylib 的 @rpath/@executable_path 路径不对或文件未随包", "用 otool -L 看实际加载路径，确认 dylib 已在目标 App 内且路径正确"),
        ("EXC_BAD_ACCESS", "崩溃", "访问已释放/空指针/非法内存（含 Hook 改错）", "检查 Hook 偏移与函数签名，确认补丁/指针未被 PAC 保护，用 diagnose 定位"),
        ("Segmentation fault", "崩溃", "非法内存访问（多为注入 dylib 或静态补丁错误）", "核对 RVA/偏移与目标版本是否一致，回滚 .bak_macho 重试"),
        ("Permission denied", "权限", "目标路径只读或未以 root 运行", "确认 TrollStore 已开编辑 Entitlements、setuid 已打；Bundle 目录需 root 写入"),
        ("No space left on device", "存储", "沙盒空间已满", "用 workspace.cleanup 清旧文件/日志，或在系统设置清理 App 存储"),
        ("Connection refused", "网络", "目标端口无服务/代理未起", "确认 server 已 start、端口正确；本地代理/抓包工具要先启动"),
        ("Could not inspect the application package", "安装", "IPA 包结构不完整或非有效 App 包", "用 package.unpack 检查包结构，确认 Info.plist 与主二进制齐全"),
        ("0x8badf00d", "崩溃", "启动被系统看门狗杀死（启动耗时过长，常见注入太重）", "减少启动期加载的 dylib/检查项，把重活延后到启动后"),
        ("0xdead10cc", "崩溃", "系统判定 App 占用/挂死（多为后台锁/IO 卡死）", "排查主线程阻塞、全量序列化大文件，检查是否有死循环"),
        ("candidate should have a different linkedit", "Mach-O", "静态注入改 __LINKEDIT 时与原签名冲突", "注入后必须 ldid 重签；优先使用注入器自带的签名流程"),
        ("Unsupported iOS version", "巨魔", "TrollStore 在该系统不被支持（17.0.1+/16.7 已修补）", "核对支持版本表；不支持版本改用越狱或其他签名方案"),
        ("apk: command not found", "iSH", "iSH 内 apk 索引未更新或环境异常", "先 apk update；确认在 iSH Alpine 内执行，不是目标 App 环境"),
        ("Illegal instruction", "iSH", "iSH 解释器未实现该 x86 指令（Node.js 等常见）", "换轻量/旧版本软件，或改用 SSH 到电脑/云端运行，别在 iSH 硬跑"),
        ("address already in use", "网络", "本地服务端口被占用", "server.status 看占用，换端口或先 stop 旧实例"),
    ]

    private func seedBuiltinPatterns() {
        guard let db = db else { return }
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v INTEGER)", nil, nil, nil)

        // v1：仅空库时插入
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM patterns", -1, &stmt, nil)
        sqlite3_step(stmt)
        let count = sqlite3_column_int(stmt, 0)
        sqlite3_finalize(stmt)
        if count == 0 {
            for (kw, cat, cause, fix) in v1Patterns { insertPattern(kw, cat, cause, fix) }
        }

        // v2：版本迁移，缺失的才插入（老用户也能拿到新种子）
        sqlite3_prepare_v2(db, "SELECT v FROM meta WHERE k='seed_version'", -1, &stmt, nil)
        var v = 0
        if sqlite3_step(stmt) == SQLITE_ROW { v = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        if v < 2 {
            for (kw, cat, cause, fix) in v2Patterns where !keywordExists(kw) {
                insertPattern(kw, cat, cause, fix)
            }
            sqlite3_exec(db, "INSERT OR REPLACE INTO meta(k,v) VALUES('seed_version',2)", nil, nil, nil)
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
        summary: "Query the crash/error knowledge base. Use for: look up known error patterns, find out what an error means and how to fix it. Don't use for: diagnose crash (use diagnose.crash), collect logs (use log.collect). Example: user says 'what does this error mean' → query knowledge base.",
        parameters: [
            "error": "Error text to look up (required)",
            "action": "query (default) or add new pattern",
            "keyword": "Keyword (when adding new pattern)",
            "cause": "Cause description (when adding)",
            "fix": "Fix solution (when adding)"
        ],
    verified: true, category: "knowledge")

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
        summary: "Clean up workspace temporary files. Use for: free up workspace space, remove old downloads/logs/reports. Don't use for: clean app cache (use cleanup.scan/execute), delete specific file (use fs.rm). Example: user says 'clean temp files in workspace' → cleanup.",
        parameters: [
            "dry_run": "Preview only, don't actually delete (default: true)",
            "max_age_days": "Delete files older than N days (default: 7)",
            "max_size_mb": "Clean when folder exceeds N MB (default: 500)",
            "targets": "What to clean: downloads/logs/reports/all (default: all)"
        ],
    verified: true, category: "cleanup")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let dryRun = (params["dry_run"] as? Bool) ?? true
        let maxAge = (params["max_age_days"] as? Int) ?? 7
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
        case "screenshots": dirsToClean = ["screenshots", "control_shots"]
        default: dirsToClean = ["downloads", "logs", "reports", "network_capture", "screenshots", "control_shots"]
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
            "hint": dryRun ? "dry-run mode, nothing deleted. Set dry_run=false to actually clean" : "cleanup done"
        ]
    }
}
