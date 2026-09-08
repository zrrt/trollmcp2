import Foundation
import SQLite3

// v2.9.111：Filza 式文件浏览与二进制分析能力。
// 提供三个工具：
//   fs.tree    —— 浏览 App 数据容器 / Bundle / 工作区的目录树
//   fs.read    —— 读取任意文件，自动识别文本 / plist / SQLite / 二进制
//   fs.hexdump —— 二进制十六进制 + ASCII 查看（offset / length 分段）

// MARK: - 路径解析与安全边界

private enum FSPolicy {
    /// 解析目标路径：bundle_id + relative（容器内相对）优先，否则按绝对路径。
    /// 返回 nil 表示无法解析。
    static func resolve(bundleId: String?, relative: String?, path: String?) -> String? {
        if let bid = bundleId, !bid.isEmpty {
            guard let app = AppCatalog.find(bid) else { return nil }
            let base = app.containerPath ?? ""
            let rel = (relative ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel.isEmpty { return base.isEmpty ? nil : base }
            return base + "/" + rel
        }
        if let p = path, !p.isEmpty { return p }
        return nil
    }

    /// 只允许访问用户数据区（App 容器 / Bundle / 工作区 / 全局偏好），
    /// 拒绝系统关键区，防止 AI 误读系统文件。
    static func isAllowed(_ raw: String) -> Bool {
        let s = (raw as NSString).standardizingPath
        let s2 = s.hasPrefix("/private/var") ? String(s.dropFirst("/private".count)) : s
        let allowed = [
            "/var/mobile/Documents/Workspace",
            "/var/mobile/Containers/Data/Application",
            "/var/mobile/Containers/Bundle/Application",
            "/var/mobile/Library"
        ]
        var ok = allowed.contains { s2.hasPrefix($0) }
        if !ok { ok = allowed.contains { s.hasPrefix($0) } }
        guard ok else { return false }
        let denied = [
            "/var/mobile/Library/Keychains",
            "/var/Keychains",
            "/var/preferences",
            "/var/db",
            "/var/containers/Shared/SystemGroup",
            "/var/mobile/Library/SpringBoard",
            "/var/mobile/Library/UserNotifications"
        ]
        for d in denied {
            if s2.hasPrefix(d) || s.hasPrefix(d) { return false }
        }
        return true
    }

    static func describe(_ raw: String) -> String {
        if let app = AppCatalog.list().first(where: { $0.containerPath.map { raw.hasPrefix($0) } ?? false }) {
            let rel = raw.dropFirst(app.containerPath!.count)
            return "\(app.bundleId) 容器\(rel)"
        }
        return raw
    }
}

// MARK: - 目录树

final class FSTreeTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.tree",
        summary: "浏览文件目录树：App 数据容器（Documents/Library/Caches/Preferences）、App Bundle、工作区。返回条目名称/类型/大小/修改时间，支持深度递归。Filza 式文件浏览。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（与 path 二选一；填了则浏览该 App 数据容器）",
            "path": "绝对路径（与 bundle_id 二选一；默认工作区根）",
            "depth": "递归深度（默认 1，最大 3）",
            "limit": "每层最多条目数（默认 60）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        let depth = min(max((params["depth"] as? Int) ?? 1, 1), 3)
        let limit = min(max((params["limit"] as? Int) ?? 60, 1), 200)

        let root: String
        if let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) {
            root = p
        } else if let ws = UserDefaults.standard.string(forKey: "trollmcp2.workspace") {
            root = ws
        } else {
            root = "/var/mobile/Documents/Workspace"
        }
        guard FSPolicy.isAllowed(root) else {
            throw MCPError.failed("路径不在可访问范围（仅限 App 容器 / Bundle / 工作区 / 用户 Library）: \(root)")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else {
            return ["error": "路径不存在: \(root)"]
        }

        var children: [[String: Any]] = []
        if isDir.boolValue {
            children = Self.scan(root, depth: depth, limit: limit)
        }
        return [
            "path": root,
            "isDir": isDir.boolValue,
            "target": FSPolicy.describe(root),
            "entries": children,
            "hint": "用 fs.read 读取文件（自动识别文本/plist/SQLite/二进制）；用 fs.hexdump 看二进制十六进制"
        ]
    }

    private static func scan(_ dir: String, depth: Int, limit: Int) -> [[String: Any]] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var out: [[String: Any]] = []
        var shown = 0
        for name in items.prefix(limit) {
            let full = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            var attrs: [FileAttributeKey: Any]? = nil
            do { attrs = try fm.attributesOfItem(atPath: full) } catch { attrs = nil }
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            var entry: [String: Any] = [
                "name": name,
                "isDir": isDir.boolValue,
                "size": isDir.boolValue ? 0 : size,
                "modified": Int64(mtime)
            ]
            if isDir.boolValue, depth > 1 {
                entry["children"] = scan(full, depth: depth - 1, limit: limit)
            }
            out.append(entry)
            shown += 1
            if shown >= limit { break }
        }
        if items.count > shown {
            out.append(["name": "...(另有 \(items.count - shown) 项未显示)", "isDir": false, "size": 0, "truncated": true])
        }
        return out
    }
}

// MARK: - 文件读取（智能识别）

final class FSReadTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.read",
        summary: "读取任意文件内容并智能识别格式：文本（UTF-8/UTF-16）、plist（XML/二进制→JSON）、SQLite（表清单）、二进制（提示改用 fs.hexdump）。Filza 式文件查看。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（与 path 二选一；填了则相对容器路径）",
            "relative": "容器内相对路径（bundle_id 模式下用，如 Library/Preferences/xx.plist）",
            "path": "绝对路径（与 bundle_id 二选一）",
            "max_bytes": "最多读取字节数（默认 524288，0 表示不限制）",
            "as": "强制格式：auto（默认）/ text / json / hex",
            "line_start": "文本从第几行开始返回（1-based，默认 1）",
            "line_end": "文本返回到第几行（默认全部）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        let force = (params["as"] as? String) ?? "auto"
        let maxBytes = max((params["max_bytes"] as? Int) ?? 524288, 0)
        let lineStart = max((params["line_start"] as? Int) ?? 1, 1)
        let lineEnd = params["line_end"] as? Int

        guard let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) else {
            throw MCPError.invalidParams("需要 bundle_id+relative 或 path")
        }
        guard FSPolicy.isAllowed(p) else {
            throw MCPError.failed("路径不在可访问范围（仅限 App 容器 / Bundle / 工作区 / 用户 Library）: \(p)")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else {
            return ["error": "路径不存在: \(p)"]
        }
        if isDir.boolValue {
            return ["error": "这是目录，用 fs.tree 浏览: \(p)"]
        }
        guard let data = fm.contents(atPath: p) else {
            return ["error": "读取失败（无权限?）: \(p)"]
        }
        let limited = maxBytes > 0 && data.count > maxBytes
        let slice = limited ? data.subdata(in: 0..<maxBytes) : data
        let size = Int64(data.count)
        var result: [String: Any] = ["path": p, "target": FSPolicy.describe(p), "size": size]
        if limited {
            result["truncated"] = true
            result["truncated_bytes"] = size - Int64(maxBytes)
        }

        if force == "hex" {
            result["kind"] = "hex"
            result["hex"] = Self.hexLines(slice, offset: 0, length: min(slice.count, 512))
            return result
        }

        // 1) SQLite
        if slice.count >= 16, slice.prefix(16).elementsEqual("SQLite format 3\u{0}".data(using: .utf8)!) {
            result["kind"] = "sqlite"
            result["tables"] = Self.sqliteTables(p)
            return result
        }
        // 2) plist（XML / 二进制）
        if force == "json" || force == "auto" {
            if let plist = try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil),
               let j = try? JSONSerialization.data(withJSONObject: plist, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: j, encoding: .utf8) {
                result["kind"] = "plist"
                result["content"] = str
                return result
            }
        }
        // 3) 文本（UTF-8 优先，UTF-16 BOM），支持按行分页
        if force == "text" || force == "auto" {
            var str: String? = nil
            var enc = "utf-8"
            if let t = String(data: slice, encoding: .utf8), !t.contains("\u{FFFD}") {
                str = t
            } else if slice.count >= 2, slice[0] == 0xFF, slice[1] == 0xFE,
                      let t = String(data: slice, encoding: .utf16LittleEndian) {
                str = t; enc = "utf-16le"
            } else if slice.count >= 2, slice[0] == 0xFE, slice[1] == 0xFF,
                      let t = String(data: slice, encoding: .utf16BigEndian) {
                str = t; enc = "utf-16be"
            }
            if let t = str {
                var lines = t.components(separatedBy: "\n")
                let totalLines = lines.count
                var startIdx = min(max(lineStart - 1, 0), totalLines)
                var endIdx = totalLines
                if let le = lineEnd { endIdx = min(max(le, 1), totalLines) }
                if endIdx < startIdx { endIdx = startIdx }
                let part = lines[startIdx..<endIdx].joined(separator: "\n")
                result["kind"] = "text"
                result["encoding"] = enc
                result["total_lines"] = totalLines
                result["line_start"] = startIdx + 1
                result["line_end"] = endIdx
                result["content"] = part
                if endIdx < totalLines {
                    result["hint"] = "还有 \(totalLines - endIdx) 行：继续用 line_start=\(endIdx + 1) 读取下一页"
                }
                return result
            }
        }
        // 4) 图片格式识别（无法在文本里查看，提示用 image / screenshot 类工具）
        if slice.count >= 12 {
            let h = [UInt8](slice.prefix(12))
            var img: String? = nil
            if h[0] == 0x89, h[1] == 0x50, h[2] == 0x4E, h[3] == 0x47 { img = "PNG" }
            else if h[0] == 0xFF, h[1] == 0xD8, h[2] == 0xFF { img = "JPEG" }
            else if h[0] == 0x47, h[1] == 0x49, h[2] == 0x46 { img = "GIF" }
            else if h[0] == 0x52, h[1] == 0x49, h[2] == 0x46, h[3] == 0x46 { img = "WebP/RIFF" }
            if let im = img {
                result["kind"] = "image"
                result["image_format"] = im
                result["hint"] = "图片文件：AI 可用 image 读取/截图类工具查看内容（本工具只识别格式）"
                return result
            }
        }
        // 4) 二进制
        result["kind"] = "binary"
        result["magic"] = slice.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        result["ascii_preview"] = slice.prefix(64).map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        result["hint"] = "二进制文件：用 fs.hexdump（offset/length 分段）或 ipa.inspect / dylib.inspect / binary.symbols 分析"
        return result
    }

    static func hexLines(_ data: Data, offset: Int, length: Int) -> String {
        let end = min(offset + length, data.count)
        var lines: [String] = []
        var i = offset
        while i < end {
            let stop = min(i + 16, end)
            let chunk = data[i..<stop]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  %-47s  |%@|", i, hex, ascii))
            i += 16
        }
        return lines.joined(separator: "\n")
    }

    private static func sqliteTables(_ p: String) -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(p, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let d = db else {
            return []
        }
        defer { sqlite3_close(d) }
        var rows: [[String: Any]] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(d, "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') ORDER BY name", -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            while sqlite3_step(s) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(s, 0))
                let type = String(cString: sqlite3_column_text(s, 1))
                rows.append(["name": name, "type": type])
            }
            sqlite3_finalize(s)
        }
        return rows
    }
}

// MARK: - 二进制十六进制查看

final class FSHexdumpTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.hexdump",
        summary: "二进制十六进制 + ASCII 查看：指定 offset/length 分段读取，适合分析 Mach-O 头、plist 二进制、配置缓存等。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（与 path 二选一）",
            "relative": "容器内相对路径（bundle_id 模式下用）",
            "path": "绝对路径（与 bundle_id 二选一）",
            "offset": "起始字节偏移（默认 0）",
            "length": "读取字节数（默认 256，最大 4096）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        let offset = max((params["offset"] as? Int) ?? 0, 0)
        let length = min(max((params["length"] as? Int) ?? 256, 1), 4096)

        guard let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) else {
            throw MCPError.invalidParams("需要 bundle_id+relative 或 path")
        }
        guard FSPolicy.isAllowed(p) else {
            throw MCPError.failed("路径不在可访问范围: \(p)")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else {
            return ["error": "文件不存在或为目录: \(p)"]
        }
        guard let data = fm.contents(atPath: p) else {
            return ["error": "读取失败（无权限?）: \(p)"]
        }
        let total = data.count
        if offset >= total {
            return ["path": p, "size": total, "error": "offset 超出文件大小"]
        }
        let slice: Data
        if offset + length <= total {
            slice = data.subdata(in: offset..<(offset + length))
        } else {
            slice = data.subdata(in: offset..<total)
        }
        var ascii = slice.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        if ascii.count > 160 { ascii = String(ascii.prefix(160)) + "…" }
        return [
            "path": p,
            "target": FSPolicy.describe(p),
            "size": total,
            "offset": offset,
            "read": slice.count,
            "hex": FSReadTool.hexLines(slice, offset: offset, length: slice.count),
            "ascii": ascii,
            "hint": "继续分段查看：把 offset 设为 \(offset + slice.count)"
        ]
    }
}


// MARK: - ZIP 浏览（IPA/归档分析）

final class FSZipTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.zip",
        summary: "ZIP/IPA 归档浏览：列出全部条目（名称/大小/压缩方式），或读取 zip 内单个文件内容（文本/plist/SQLite/hex 识别）。IPA 本质是 zip，直接用它分析 IPA 内部。",
        parameters: [
            "path": "ZIP/IPA 文件绝对路径（必填）",
            "action": "list（默认，列条目）/ read（读条目）",
            "entry": "action=read 时要读取的条目名",
            "as": "read 时格式：auto（默认）/ text / json / hex",
            "filter": "list 时按文件名关键词过滤（可选）",
            "limit": "list 返回条数上限（默认 200）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        guard FSPolicy.isAllowed(path) else {
            throw MCPError.failed("路径不在可访问范围: \(path)")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return ["error": "读取失败: \(path)"]
        }
        let action = (params["action"] as? String) ?? "list"
        let filter = (params["filter"] as? String)?.lowercased()

        do {
            if action == "read" {
                guard let entry = params["entry"] as? String, !entry.isEmpty else {
                    throw MCPError.invalidParams("action=read 需要 entry 参数")
                }
                let raw = try ZipExtractor.entryData(data, name: entry)
                let force = (params["as"] as? String) ?? "auto"
                var out: [String: Any] = ["zip": path, "entry": entry, "size": raw.count]
                if raw.count > 1_048_576 {
                    out["hint"] = "条目超过 1MB，已截断为前 1MB"
                }
                let slice = raw.prefix(1_048_576)
                if force == "hex" {
                    out["kind"] = "hex"
                    out["hex"] = FSReadTool.hexLines(Data(slice), offset: 0, length: min(slice.count, 512))
                    return out
                }
                if let plist = try? PropertyListSerialization.propertyList(from: Data(slice), options: [], format: nil),
                   let j = try? JSONSerialization.data(withJSONObject: plist, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: j, encoding: .utf8), force != "text" {
                    out["kind"] = "plist"
                    out["content"] = str
                    return out
                }
                if let str = String(data: Data(slice), encoding: .utf8), !str.contains("\u{FFFD}") {
                    out["kind"] = "text"
                    out["content"] = str
                    return out
                }
                out["kind"] = "binary"
                out["magic"] = slice.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                out["hint"] = "二进制条目：用 fs.zip action=read as=hex 查看十六进制"
                return out
            }
            // list
            let entries = try ZipExtractor.entries(data)
            let limit = min(max((params["limit"] as? Int) ?? 200, 1), 1000)
            var list: [[String: Any]] = []
            var totalSize: Int64 = 0
            for e in entries {
                if let f = filter, !e.name.lowercased().contains(f) { continue }
                if list.count >= limit { break }
                totalSize += Int64(e.uncompSize)
                list.append([
                    "name": e.name,
                    "isDir": e.isDir,
                    "size": e.uncompSize,
                    "compressed": e.compSize,
                    "method": e.method == 0 ? "store" : (e.method == 8 ? "deflate" : "method\(e.method)")
                ])
            }
            var out: [String: Any] = [
                "zip": path,
                "target": FSPolicy.describe(path),
                "total_entries": entries.count,
                "shown": list.count,
                "total_uncompressed": totalSize,
                "entries": list
            ]
            if entries.count > list.count { out["hint"] = "还有 \(entries.count - list.count) 个条目未显示（可用 filter 过滤）" }
            return out
        } catch let e as ZipExtractor.ZipError {
            return ["error": e.description, "path": path]
        } catch {
            return ["error": "解析失败: \(error.localizedDescription)"]
        }
    }
}

// MARK: - SQLite 查询

final class FSSQLTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.sql",
        summary: "SQLite 数据库只读查询：默认列出数据表，支持 SELECT/PRAGMA 查询（自动加 LIMIT 防止返回过大）。Filza 的 SQLite3 编辑器能力。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（与 path 二选一）",
            "relative": "容器内相对路径（bundle_id 模式下用，如 Documents/xx.db）",
            "path": "数据库绝对路径（与 bundle_id 二选一）",
            "sql": "SQL 语句（默认列出全部表与视图）",
            "limit": "最多返回行数（默认 100，最大 500）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        guard let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) else {
            throw MCPError.invalidParams("需要 bundle_id+relative 或 path")
        }
        guard FSPolicy.isAllowed(p) else {
            throw MCPError.failed("路径不在可访问范围: \(p)")
        }
        let sql = (params["sql"] as? String) ?? "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') ORDER BY name"
        let limit = min(max((params["limit"] as? Int) ?? 100, 1), 500)

        // 只允许只读语句
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        let allowed = upper.hasPrefix("SELECT") || upper.hasPrefix("PRAGMA") || upper.hasPrefix("EXPLAIN") || upper.hasPrefix("WITH")
        guard allowed else {
            throw MCPError.failed("只允许只读 SQL（SELECT/PRAGMA/EXPLAIN/WITH），禁止修改语句")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(p, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let d = db else {
            return ["error": "打开数据库失败（不是 SQLite 文件?）: \(p)"]
        }
        defer { sqlite3_close(d) }

        // 强制 LIMIT（已带 LIMIT 的语句跳过）
        var exec = trimmed
        if !upper.contains("LIMIT") && upper.hasPrefix("SELECT") {
            exec = trimmed + " LIMIT \(limit)"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(d, exec, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(d))
            return ["error": "SQL 错误: \(msg)", "sql": trimmed]
        }
        defer { sqlite3_finalize(s) }

        let colCount = sqlite3_column_count(s)
        var columns: [String] = []
        if colCount > 0 {
            for c in 0..<colCount {
                columns.append(String(cString: sqlite3_column_name(s, c)))
            }
        }
        var rows: [[Any]] = []
        while sqlite3_step(s) == SQLITE_ROW {
            var row: [Any] = []
            for c in 0..<colCount {
                switch sqlite3_column_type(s, c) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(s, c))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(s, c))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(s, c)))
                case SQLITE_BLOB:
                    let n = sqlite3_column_bytes(s, c)
                    row.append("blob(\(n)B)")
                default: row.append(NSNull())
                }
            }
            rows.append(row)
            if rows.count >= limit { break }
        }
        return [
            "path": p,
            "target": FSPolicy.describe(p),
            "sql": trimmed,
            "columns": columns,
            "rows": rows,
            "row_count": rows.count,
            "hint": "继续查询：改 sql 加 WHERE/ORDER BY；看表结构用 PRAGMA table_info(表名)"
        ]
    }
}

// MARK: - 文本搜索

final class FSGrepTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.grep",
        summary: "在目录内搜索文本文件内容（关键词匹配），返回 文件:行号:匹配行。适合找配置、日志、源码里的关键词。",
        parameters: [
            "dir": "搜索目录（默认工作区；bundle_id 模式看下方）",
            "bundle_id": "目标 App Bundle ID（填了则在该 App 数据容器内搜索）",
            "pattern": "搜索关键词（必填，不区分大小写）",
            "ext": "文件扩展名过滤（如 plist/json/log/txt，逗号分隔，可选）",
            "limit": "最多返回匹配条数（默认 60）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let pattern = params["pattern"] as? String, !pattern.isEmpty else {
            throw MCPError.invalidParams("pattern required")
        }
        let bundleId = params["bundle_id"] as? String
        let dir: String
        if let p = FSPolicy.resolve(bundleId: bundleId, relative: nil, path: params["dir"] as? String) {
            dir = p
        } else if let ws = UserDefaults.standard.string(forKey: "trollmcp2.workspace") {
            dir = ws
        } else {
            dir = "/var/mobile/Documents/Workspace"
        }
        guard FSPolicy.isAllowed(dir) else {
            throw MCPError.failed("路径不在可访问范围: \(dir)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return ["error": "目录不存在: \(dir)"]
        }
        let exts = (params["ext"] as? String)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
        let limit = min(max((params["limit"] as? Int) ?? 60, 1), 300)
        let needle = pattern.lowercased()

        var hits: [[String: Any]] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return ["dir": dir, "hits": []] }
        var scanned = 0
        for case let name as String in en {
            if hits.count >= limit { break }
            scanned += 1
            if scanned > 4000 { break }
            let full = (dir as NSString).appendingPathComponent(name)
            var isD: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isD)
            if isD.boolValue { continue }
            let ext = (full as NSString).pathExtension.lowercased()
            if !exts.isEmpty, !exts.contains(ext) { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size < 524_288 else { continue }
            guard let data = fm.contents(atPath: full),
                  let text = String(data: data, encoding: .utf8), !text.contains("\u{FFFD}") else { continue }
            for (idx, line) in text.components(separatedBy: "\n").enumerated() {
                if hits.count >= limit { break }
                if line.lowercased().contains(needle) {
                    hits.append([
                        "file": name,
                        "line": idx + 1,
                        "text": String(line.prefix(300))
                    ])
                }
            }
        }
        return [
            "dir": dir,
            "pattern": pattern,
            "scanned_files": scanned,
            "hits": hits,
            "hit_count": hits.count,
            "hint": "搜索到目标后用 fs.read 读取文件（line_start/line_end 定位行）"
        ]
    }
}
