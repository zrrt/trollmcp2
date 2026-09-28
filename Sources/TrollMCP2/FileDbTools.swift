import Foundation

// MARK: - v3.6.12 P5 高层跨环境工具 (v3.7.7: 复用 ISHEngine 自动 bind——Alpine 直接读写 iOS 文件)

/// 高层文件检查/分析工具。inspect 走原生读元信息；analyze 走 Alpine (自动 bind 直读 iOS 文件) 跑 file+strings。
final class FileExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "file",
        summary: "High-level cross-environment file inspection (uses automatic iOS bind — Alpine reads iOS files directly). inspect → native metadata (size, magic type, sqlite/zip/macho detection). analyze → Alpine `file` + `strings` on the iOS file. Use for: quickly identify what a file is, extract strings from a decrypted binary/db. Don't use for: edit files (shell), network. Example: file inspect path:/var/mobile/.../x.db; file analyze path:/var/mobile/.../binary. Subcommands: inspect / analyze. REQUIRED: path (iOS absolute path).",
        parameters: [
            "command": "Subcommand (required): inspect / analyze",
            "path": "iOS absolute file path (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required: inspect / analyze")
        }
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        let norm = ShellExecTool.normalizePath(path)
        let fm = FileManager.default
        switch command {
        case "inspect":
            guard fm.fileExists(atPath: norm) else { throw MCPError.failed("file: no such file \(norm)") }
            guard let size = (try? fm.attributesOfItem(atPath: norm)[.size]) as? Int else {
                throw MCPError.failed("file: cannot stat \(norm)")
            }
            var type = "unknown"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: norm), options: .mappedIfSafe) {
                type = FileExecTool.detectType([UInt8](data.prefix(16)))
            }
            return ["path": norm, "size_bytes": size, "type": type]
        case "analyze":
            guard fm.fileExists(atPath: norm) else { throw MCPError.failed("file: no such file \(norm)") }
            // v3.7.7: 先 autoBind 改写为 Alpine 可见路径(/ios_*)，再 base64 传路径。
            // （直接用明文 iOS 路径会被 autoBind 改写；base64 保护仍防 shell 元字符注入，但改写须先发生）
            let boundPath = ISHManager.autoBind(norm)
            let pb = Data(boundPath.utf8).base64EncodedString()
            let out = ISHEngine.exec("P=$(echo '\(pb)' | base64 -d); file \"$P\"; echo '--- strings (first 80) ---'; strings -a \"$P\" 2>/dev/null | head -80", timeout: 60)
            return ["env": "alpine", "exit_code": Int(out.exitCode), "output": out.output]
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: inspect / analyze")
        }
    }

    /// 依据文件头魔数推断类型
    static func detectType(_ head: [UInt8]) -> String {
        if head.count >= 4 {
            let u = Array(head.prefix(4))
            let macho: [(UInt8, UInt8, UInt8, UInt8)] = [(0xFE,0xED,0xFA,0xCE),(0xFE,0xED,0xFA,0xCF),(0xCE,0xFA,0xED,0xFE),(0xCF,0xFA,0xED,0xFE)]
            for m in macho where u == [m.0, m.1, m.2, m.3] { return "macho-binary" }
            if u[0] == 0x50 && u[1] == 0x4B { return "zip/ipa" }
            if u[0] == 0x7F && u[1] == 0x45 && u[2] == 0x4C && u[3] == 0x46 { return "elf-binary" }
        }
        let magic = String(decoding: head.prefix(15), as: UTF8.self)
        if magic.hasPrefix("SQLite format 3") { return "sqlite-db" }
        if magic.hasPrefix("fTyp") { return "font" }
        if head.count > 0, head.allSatisfy({ $0 == 10 || $0 == 13 || $0 == 9 || ($0 >= 32 && $0 < 127) }) { return "text" }
        return "binary"
    }
}

/// 高层 SQLite 分析工具。自动 bind 直读 iOS .db 文件进 Alpine，跑 sqlite3。子命令 list / schema / query。
final class DbExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "db",
        summary: "High-level SQLite database analysis (auto-binds the iOS .db file into Alpine and runs sqlite3 there). list → table names; schema → CREATE statements; query → run an SQL SELECT. Use for: inspect/query an iOS .db (WeChat/Alipay/etc). Don't use for: editing schema/data. Example: db list path:/var/mobile/.../x.db; db schema path:...; db query path:... sql:SELECT * FROM t LIMIT 5. Subcommands: list / schema / query. REQUIRED: path; query needs sql.",
        parameters: [
            "command": "Subcommand (required): list / schema / query",
            "path": "iOS absolute db path (required, auto-bind Alpine reads directly)",
            "sql": "SQL for query (required when command=query)"
        ], verified: true, category: "data")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required: list / schema / query")
        }
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        let norm = ShellExecTool.normalizePath(path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: norm) else { throw MCPError.failed("db: no such file \(norm)") }
        switch command {
        case "list":
            let out = ISHEngine.exec("sqlite3 '\(norm)' \".tables\"", timeout: 60)
            return ["env": "alpine", "exit_code": Int(out.exitCode), "output": out.output]
        case "schema":
            let out = ISHEngine.exec("sqlite3 '\(norm)' \".schema\"", timeout: 60)
            return ["env": "alpine", "exit_code": Int(out.exitCode), "output": out.output]
        case "query":
            guard let sql = params["sql"] as? String, !sql.isEmpty else {
                throw MCPError.invalidParams("sql required for query")
            }
            // v3.6.19h: 修复命令注入——原实现把 SQL 直接拼进 shell 双引号，单引号转义成 '"'"' 含双引号，
            // 在双引号上下文反破引号平衡，含 ;/$/` 等元字符的 SQL 可执行任意命令。改为 base64 编码 SQL
            // (仅 [A-Za-z0-9+/=] 安全字符)，Alpine 侧解码写临时文件，sqlite3 从 stdin 读，彻底绕开 shell 解析。
            let b64 = Data(sql.utf8).base64EncodedString()
            let out = ISHEngine.exec("echo '\(b64)' | base64 -d > /tmp/_db_q.sql; sqlite3 -header -column '\(norm)' < /tmp/_db_q.sql", timeout: 90)
            return ["env": "alpine", "exit_code": Int(out.exitCode), "output": out.output]
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: list / schema / query")
        }
    }
}
