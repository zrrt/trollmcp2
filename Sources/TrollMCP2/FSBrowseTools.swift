import Foundation
import SQLite3
import CommonCrypto

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

    /// 是否可写：仅工作区与 App 数据容器（Documents/Library 等），禁止 App Bundle 与系统区。
    static func isWritable(_ raw: String) -> Bool {
        guard isAllowed(raw) else { return false }
        let s = (raw as NSString).standardizingPath
        let s2 = s.hasPrefix("/private/var") ? String(s.dropFirst("/private".count)) : s
        let ok = s2.hasPrefix("/var/mobile/Documents/Workspace") || s2.hasPrefix("/var/mobile/Containers/Data/Application")
        guard ok else { return false }
        if s2.hasPrefix("/var/mobile/Containers/Bundle") { return false }
        return true
    }

    /// 工作区根路径
    static func workspace() -> String {
        if let ws = UserDefaults.standard.string(forKey: "trollmcp2.workspace"), !ws.isEmpty { return ws }
        return "/var/mobile/Documents/Workspace"
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

        // v2.9.114：PRAGMA 只放行查询型，拒绝赋值型（journal_mode=WAL 等）
        if upper.hasPrefix("PRAGMA") && upper.contains("=") {
            throw MCPError.failed("只允许查询型 PRAGMA（table_info/index_list 等），禁止赋值型")
        }
        // 强制 LIMIT（已带 LIMIT 的语句跳过）；先剥尾部分号，避免 LIMIT 被当成第二条语句失效
        var exec = trimmed
        while exec.hasSuffix(";") { exec = String(exec.dropLast()) }
        if !upper.contains("LIMIT") && upper.hasPrefix("SELECT") {
            exec = exec + " LIMIT \(limit)"
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


// MARK: - 文件写入（带自动备份）

final class FSWriteTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.write",
        summary: "写文本/JSON 到文件（工作区或 App 数据容器）。已有文件自动备份 .bak。禁止写 App Bundle 与系统区。Filza 的文本编辑器写能力。",
        parameters: [
            "path": "绝对路径（或工作区相对路径）",
            "bundle_id": "目标 App Bundle ID（填了则写该 App 数据容器）",
            "relative": "容器内相对路径（bundle_id 模式下用）",
            "content": "要写入的文本内容（必填）",
            "backup": "覆盖前是否备份为 .bak（默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let content = params["content"] as? String else {
            throw MCPError.invalidParams("content required")
        }
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        let backup = (params["backup"] as? Bool) ?? true

        var target: String? = nil
        if let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) {
            target = p
        } else if let p = path, !p.hasPrefix("/") {
            // 工作区相对路径
            target = FSPolicy.workspace() + "/" + p
        }
        guard let p = target else { throw MCPError.invalidParams("需要 path 或 bundle_id+relative") }
        guard FSPolicy.isWritable(p) else {
            throw MCPError.failed("不可写：仅限工作区与 App 数据容器（Documents/Library），禁止 Bundle 与系统区: \(p)")
        }
        let fm = FileManager.default
        let parent = (p as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        var bakCreated = false
        if fm.fileExists(atPath: p), backup {
            try? fm.removeItem(atPath: p + ".bak")
            if (try? fm.copyItem(atPath: p, toPath: p + ".bak")) != nil { bakCreated = true }
        }
        do {
            try Data(content.utf8).write(to: URL(fileURLWithPath: p))
        } catch {
            return ["error": "写入失败: \(error.localizedDescription)", "path": p]
        }
        var out: [String: Any] = ["path": p, "bytes": content.utf8.count, "backup_created": bakCreated]
        if bakCreated { out["backup_path"] = p + ".bak" }
        return out
    }
}

// MARK: - 行级编辑（带自动备份）

final class FSEditTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.edit",
        summary: "编辑文本文件：按行号替换（line + new_text）或按原文替换（old + new）。自动备份 .bak。Filza 属性表/文本编辑器写能力。",
        parameters: [
            "path": "绝对路径（或工作区相对路径）",
            "bundle_id": "目标 App Bundle ID（填了则编辑该 App 数据容器）",
            "relative": "容器内相对路径（bundle_id 模式下用）",
            "line": "要替换的行号（1-based，与 new_text 搭配）",
            "new_text": "替换后的内容（line 模式下）",
            "old": "原文片段（old/new 模式下）",
            "new": "替换为（old/new 模式下，可选则删除该片段）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        var target: String? = nil
        if let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) {
            target = p
        } else if let p = path, !p.hasPrefix("/") {
            target = FSPolicy.workspace() + "/" + p
        }
        guard let p = target else { throw MCPError.invalidParams("需要 path 或 bundle_id+relative") }
        guard FSPolicy.isWritable(p) else {
            throw MCPError.failed("不可写：仅限工作区与 App 数据容器: \(p)")
        }
        let fm = FileManager.default
        guard let data = fm.contents(atPath: p), var text = String(data: data, encoding: .utf8) else {
            return ["error": "读取失败或非 UTF-8 文本: \(p)"]
        }
        var changed = false
        var detail = ""
        if let line = params["line"] as? Int, let newText = params["new_text"] as? String {
            var lines = text.components(separatedBy: "\n")
            guard line >= 1, line <= lines.count else {
                return ["error": "行号越界: \(line)（共 \(lines.count) 行）"]
            }
            let oldLine = lines[line - 1]
            lines[line - 1] = newText
            text = lines.joined(separator: "\n")
            changed = true
            detail = "L\(line): \(String(oldLine.prefix(80))) → \(String(newText.prefix(80)))"
        } else if let old = params["old"] as? String, !old.isEmpty {
            let replacement = (params["new"] as? String) ?? ""
            let count = text.components(separatedBy: old).count - 1
            guard count > 0 else { return ["error": "未找到原文片段"] }
            text = text.replacingOccurrences(of: old, with: replacement)
            changed = true
            detail = "替换 \(count) 处"
        }
        guard changed else { throw MCPError.invalidParams("需要 line+new_text 或 old(+new) 参数") }

        try? fm.removeItem(atPath: p + ".bak")
        try? fm.copyItem(atPath: p, toPath: p + ".bak")
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: p))
        } catch {
            return ["error": "写入失败: \(error.localizedDescription)"]
        }
        return ["path": p, "changed": detail, "backup_path": p + ".bak"]
    }
}

// MARK: - 文件对比

final class FSDiffTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.diff",
        summary: "对比两个文件：文本逐行 diff（+新增/-删除），二进制比大小与 SHA256 与首个差异偏移。用于对比不同版本、备份 vs 当前、配置差异。",
        parameters: [
            "path_a": "文件 A（绝对路径或工作区相对路径）",
            "path_b": "文件 B",
            "bundle_id_a": "文件 A 的 App Bundle ID（可选）",
            "relative_a": "文件 A 容器内相对路径（bundle_id_a 模式下用）",
            "bundle_id_b": "文件 B 的 App Bundle ID（可选）",
            "relative_b": "文件 B 容器内相对路径（bundle_id_b 模式下用）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let pa = Self.resolveOne(params, prefix: "a", key: "path_a") else {
            throw MCPError.invalidParams("path_a required")
        }
        guard let pb = Self.resolveOne(params, prefix: "b", key: "path_b") else {
            throw MCPError.invalidParams("path_b required")
        }
        guard FSPolicy.isAllowed(pa), FSPolicy.isAllowed(pb) else {
            throw MCPError.failed("路径不在可访问范围")
        }
        let fm = FileManager.default
        guard let da = fm.contents(atPath: pa), let db = fm.contents(atPath: pb) else {
            return ["error": "读取失败"]
        }
        // 二进制哈希对比
        let hashA = Self.sha256Hex(da)
        let hashB = Self.sha256Hex(db)
        if hashA != hashB {
            var firstDiff = -1
            let n = min(da.count, db.count)
            for i in 0..<n {
                if da[i] != db[i] { firstDiff = i; break }
            }
            if firstDiff == -1 { firstDiff = n }
            // 尝试文本 diff
            let ta = String(data: da, encoding: .utf8)?.components(separatedBy: "\n")
            let tb = String(data: db, encoding: .utf8)?.components(separatedBy: "\n")
            if let la = ta, let lb = tb, la.count <= 1500, lb.count <= 1500 {
                let d = Self.lcsDiff(la, lb, maxLines: 200)
                return [
                    "equal": false,
                    "kind": "text",
                    "hash_a": hashA, "hash_b": hashB,
                    "lines_a": la.count, "lines_b": lb.count,
                    "diff": d,
                    "hint": "文本差异 \(d.count) 行"
                ]
            }
            return [
                "equal": false,
                "kind": "binary",
                "size_a": da.count, "size_b": db.count,
                "hash_a": hashA, "hash_b": hashB,
                "first_diff_offset": firstDiff,
                "hint": "二进制不同：用 fs.hexdump offset=\(firstDiff) 查看差异区域"
            ]
        }
        return ["equal": true, "size": da.count, "hash": hashA]
    }

    private static func resolveOne(_ params: [String: Any], prefix: String, key: String) -> String? {
        if let p = params[key] as? String, !p.isEmpty {
            if p.hasPrefix("/") { return p }
            return FSPolicy.workspace() + "/" + p
        }
        if let bid = params["bundle_id_\(prefix)"] as? String {
            return FSPolicy.resolve(bundleId: bid, relative: params["relative_\(prefix)"] as? String, path: nil)
        }
        return nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 简单 LCS 行级 diff（限制行数与输出量）
    private static func lcsDiff(_ a: [String], _ b: [String], maxLines: Int) -> [[String: Any]] {
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in (0..<n).reversed() {
            for j in (0..<m).reversed() {
                dp[i][j] = a[i] == b[j] ? dp[i+1][j+1] + 1 : max(dp[i+1][j], dp[i][j+1])
            }
        }
        var out: [[String: Any]] = []
        var i = 0, j = 0
        while i < n, j < m, out.count < maxLines {
            if a[i] == b[j] { i += 1; j += 1 }
            else if dp[i+1][j] >= dp[i][j+1] {
                out.append(["op": "-", "line_a": i + 1, "text": String(a[i].prefix(200))]); i += 1
            } else {
                out.append(["op": "+", "line_b": j + 1, "text": String(b[j].prefix(200))]); j += 1
            }
        }
        while i < n, out.count < maxLines { out.append(["op": "-", "line_a": i + 1, "text": String(a[i].prefix(200))]); i += 1 }
        while j < m, out.count < maxLines { out.append(["op": "+", "line_b": j + 1, "text": String(b[j].prefix(200))]); j += 1 }
        if i < n || j < m { out.append(["op": "...", "text": "差异过长已截断"]) }
        return out
    }
}

// MARK: - 哈希与元数据

final class FSHashTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.hash",
        summary: "计算文件哈希（MD5/SHA1/SHA256/SHA512）并返回大小/修改时间/权限。用于下载产物完整性校验、文件去重、对比。",
        parameters: [
            "path": "绝对路径（或工作区相对路径）",
            "bundle_id": "目标 App Bundle ID（填了则读该 App 数据容器）",
            "relative": "容器内相对路径（bundle_id 模式下用）",
            "algo": "md5 / sha1 / sha256（默认）/ sha512"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        var target: String? = nil
        if let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) {
            target = p
        } else if let p = path, !p.isEmpty {
            target = p.hasPrefix("/") ? p : FSPolicy.workspace() + "/" + p
        }
        guard let p = target else { throw MCPError.invalidParams("需要 path 或 bundle_id+relative") }
        guard FSPolicy.isAllowed(p) else { throw MCPError.failed("路径不在可访问范围: \(p)") }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else {
            return ["error": "文件不存在或为目录: \(p)"]
        }
        guard let data = fm.contents(atPath: p) else { return ["error": "读取失败: \(p)"] }
        let algo = (params["algo"] as? String)?.lowercased() ?? "sha256"
        var hash = ""
        switch algo {
        case "md5": hash = Self.digestHex(data, CC_MD5, CC_MD5_DIGEST_LENGTH)
        case "sha1": hash = Self.digestHex(data, CC_SHA1, CC_SHA1_DIGEST_LENGTH)
        case "sha512": hash = Self.digestHex(data, CC_SHA512, CC_SHA512_DIGEST_LENGTH)
        default:
            var d = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { buf in _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &d) }
            hash = d.map { String(format: "%02x", $0) }.joined()
        }
        let attrs = try? fm.attributesOfItem(atPath: p)
        var out: [String: Any] = [
            "path": p,
            "algo": algo == "md5" ? "md5" : (algo == "sha1" ? "sha1" : (algo == "sha512" ? "sha512" : "sha256")),
            "hash": hash,
            "size": (attrs?[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        ]
        if let m = attrs?[.modificationDate] as? Date { out["modified"] = Int64(m.timeIntervalSince1970) }
        if let perm = attrs?[.posixPermissions] as? NSNumber { out["permissions"] = String(format: "%o", perm.intValue) }
        if let owner = attrs?[.ownerAccountName] as? String { out["owner"] = owner }
        return out
    }

    private static func digestHex(_ data: Data, _ fn: (UnsafeRawPointer?, CC_LONG, UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>?, _ len: Int32) -> String {
        var d = [UInt8](repeating: 0, count: Int(len))
        data.withUnsafeBytes { buf in _ = fn(buf.baseAddress, CC_LONG(data.count), &d) }
        return d.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 文件名搜索

final class FSFindTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.find",
        summary: "按文件名关键词在目录内搜索（fs.grep 是搜内容，这个搜文件名），支持扩展名过滤。适合在 App 容器/工作区里找文件。",
        parameters: [
            "dir": "搜索目录（默认工作区）",
            "bundle_id": "目标 App Bundle ID（填了则在该 App 数据容器内搜索）",
            "name": "文件名关键词（必填，不区分大小写）",
            "ext": "扩展名过滤（如 plist/db/dylib，逗号分隔，可选）",
            "limit": "最多返回条数（默认 60）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        let bundleId = params["bundle_id"] as? String
        let dir: String
        if let p = FSPolicy.resolve(bundleId: bundleId, relative: nil, path: params["dir"] as? String) {
            dir = p
        } else {
            dir = FSPolicy.workspace()
        }
        guard FSPolicy.isAllowed(dir) else { throw MCPError.failed("路径不在可访问范围: \(dir)") }
        let needle = name.lowercased()
        let exts = (params["ext"] as? String)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
        let limit = min(max((params["limit"] as? Int) ?? 60, 1), 300)
        var hits: [[String: Any]] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return ["dir": dir, "hits": []] }
        var scanned = 0
        for case let n as String in en {
            if hits.count >= limit { break }
            scanned += 1
            if scanned > 6000 { break }
            let full = (dir as NSString).appendingPathComponent(n)
            var isD: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isD)
            if isD.boolValue { continue }
            guard n.lowercased().contains(needle) else { continue }
            let ext = (full as NSString).pathExtension.lowercased()
            if !exts.isEmpty, !exts.contains(ext) { continue }
            let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.int64Value ?? 0
            hits.append(["name": n, "path": full, "size": size])
        }
        return ["dir": dir, "keyword": name, "scanned": scanned, "hits": hits, "hit_count": hits.count]
    }
}

// MARK: - 下载到工作区

final class FSDownloadTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.download",
        summary: "从 URL 下载文件到工作区 downloads 目录（http/https），返回本地路径与哈希，供后续 fs.read / fs.zip / ipa.inspect 分析。",
        parameters: [
            "url": "http/https 下载地址（必填）",
            "filename": "保存的文件名（默认取 URL 最后一段）",
            "subdir": "工作区下子目录（默认 downloads）",
            "timeout": "超时秒数（默认 60）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let urlStr = params["url"] as? String,
              let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw MCPError.invalidParams("需要有效的 http/https URL")
        }
        let timeout = max((params["timeout"] as? Int) ?? 60, 5)
        let subdir = (params["subdir"] as? String) ?? "downloads"
        let base = FSPolicy.workspace() + "/" + subdir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fm = FileManager.default
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        var filename = (params["filename"] as? String) ?? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        // v2.9.114：防路径穿越——文件名剔除路径分隔符与控制字符
        let bad = CharacterSet(charactersIn: "/\\\0\n\r\t")
        filename = filename.components(separatedBy: bad).joined(separator: "_")
        if filename.isEmpty || filename == "." || filename == ".." { filename = "download" }
        let dest = base + "/" + filename

        var req = URLRequest(url: url, timeoutInterval: TimeInterval(timeout))
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = ["error": "下载失败"]
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result["error"] = "网络错误: \(err.localizedDescription)"; return }
            guard let data = data else { result["error"] = "无数据"; return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { result["error"] = "HTTP \(status)"; return }
            do {
                try data.write(to: URL(fileURLWithPath: dest))
                var d = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                data.withUnsafeBytes { buf in _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &d) }
                let hash = d.map { String(format: "%02x", $0) }.joined()
                result = ["ok": true, "path": dest, "size": data.count, "sha256": hash]
            } catch {
                result["error"] = "写入失败: \(error.localizedDescription)"
            }
        }.resume()
        _ = sem.wait(timeout: .now() + TimeInterval(timeout + 15))
        return result
    }
}


// MARK: - plist 键值编辑（Filza 属性表编辑器写能力）

final class FSPropertyListTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.plist",
        summary: "plist 键值读写（支持二进制 plist）：get 读值、set 改值、delete 删键。key 用点路径如 Root.NSAppTransportSecurity.NSAllowsArbitraryLoads。自动备份 .bak。Filza 属性表编辑器写能力。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（与 path 二选一）",
            "relative": "容器内相对路径（bundle_id 模式下用）",
            "path": "plist 绝对路径（与 bundle_id 二选一）",
            "action": "get（默认）/ set / delete",
            "key": "键路径，点号分隔，如 Root.Foo.Bar",
            "value": "set 时的值（自动识别 true/false/数字/JSON/字符串）",
            "backup": "写操作前是否备份 .bak（默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        guard let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) else {
            throw MCPError.invalidParams("需要 bundle_id+relative 或 path")
        }
        let action = (params["action"] as? String) ?? "get"
        let key = (params["key"] as? String) ?? ""
        let isWrite = action != "get"
        if isWrite {
            guard FSPolicy.isWritable(p) else {
                throw MCPError.failed("不可写：仅限工作区与 App 数据容器: \(p)")
            }
            guard !key.isEmpty else { throw MCPError.invalidParams("写操作需要 key") }
        } else {
            guard FSPolicy.isAllowed(p) else { throw MCPError.failed("路径不在可访问范围: \(p)") }
        }
        let fm = FileManager.default
        guard let data = fm.contents(atPath: p) else { return ["error": "读取失败: \(p)"] }
        let isBinary = data.count >= 8 && data.prefix(8) == Data("bplist00".utf8)
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil) else {
            return ["error": "不是合法 plist: \(p)"]
        }
        let keys = key.split(separator: ".").map(String.init)

        if action == "get" {
            guard !keys.isEmpty else {
                return ["path": p, "format": isBinary ? "binary" : "xml", "root_type": Self.typeName(obj), "root": obj]
            }
            if let v = Self.lookup(obj, keys) {
                return ["path": p, "key": key, "value": v, "type": Self.typeName(v)]
            }
            return ["path": p, "key": key, "found": false]
        }

        // 写操作：备份
        if params["backup"] as? Bool ?? true {
            try? fm.removeItem(atPath: p + ".bak")
            try? fm.copyItem(atPath: p, toPath: p + ".bak")
        }

        do {
            guard var root = obj as AnyObject? else { throw MCPError.failed("plist 根不是容器") }
            if action == "set" {
                let val = Self.coerce(params["value"] as? String ?? "")
                try Self.set(&root, keys: keys, value: val)
            } else { // delete
                try Self.delete(&root, keys: keys)
            }
            let fmt: PropertyListSerialization.PropertyListFormat = isBinary ? .binary : .xml
            guard let out = try? PropertyListSerialization.data(fromPropertyList: root, format: fmt, options: 0) else {
                return ["error": "序列化失败（可能有不支持的根类型）"]
            }
            try out.write(to: URL(fileURLWithPath: p))
            return ["path": p, "action": action, "key": key, "format": isBinary ? "binary" : "xml", "bytes": out.count, "backup_path": p + ".bak"]
        } catch let e as MCPError {
            throw e
        } catch {
            return ["error": "操作失败: \(error.localizedDescription)"]
        }
    }

    private static func typeName(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if v is Bool { return "bool" }
        if v is NSNumber { return "number" }
        if v is String { return "string" }
        if v is Data { return "data" }
        if v is Date { return "date" }
        if v is [Any] { return "array" }
        if v is [String: Any] { return "dict" }
        return String(describing: type(of: v))
    }

    private static func lookup(_ obj: Any, _ keys: [String]) -> Any? {
        var node: Any = obj
        for (i, k) in keys.enumerated() {
            if let d = node as? [String: Any] {
                guard let v = d[k] else { return nil }
                node = v
            } else if let a = node as? [Any], let idx = Int(k), idx >= 0, idx < a.count {
                node = a[idx]
            } else { return nil }
            if i == keys.count - 1 { return node }
        }
        return node
    }

    private static func coerce(_ raw: String) -> Any {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch t.lowercased() {
        case "true": return true
        case "false": return false
        case "null", "nil": return NSNull()
        default: break
        }
        if let n = Int64(t) { return NSNumber(value: n) }
        if let d = Double(t) { return NSNumber(value: d) }
        if let j = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.mutableContainers]) {
            return j
        }
        return raw
    }

    private static func set(_ root: inout AnyObject, keys: [String], value: Any) throws {
        var node: AnyObject = root
        for k in keys.dropLast() {
            if let d = node as? NSMutableDictionary {
                if let next = d[k] {
                    node = next as AnyObject
                } else {
                    let created = NSMutableDictionary()
                    d[k] = created
                    node = created
                }
            } else if let a = node as? NSMutableArray, let idx = Int(k) {
                while a.count <= idx { a.add(NSMutableDictionary()) }
                node = a[idx] as AnyObject
            } else {
                throw MCPError.failed("键路径中间节点不是字典/数组: \(k)")
            }
        }
        guard let last = keys.last else { throw MCPError.invalidParams("key 不能为空") }
        if let d = node as? NSMutableDictionary {
            d[last] = value
        } else if let a = node as? NSMutableArray, let idx = Int(last) {
            while a.count <= idx { a.add(NSNull()) }
            a[idx] = value
        } else {
            throw MCPError.failed("键路径末端不是字典/数组: \(last)")
        }
    }

    private static func delete(_ root: inout AnyObject, keys: [String]) throws {
        var node: AnyObject = root
        for k in keys.dropLast() {
            if let d = node as? NSMutableDictionary {
                guard let next = d[k] else { throw MCPError.failed("键不存在: \(k)") }
                node = next as AnyObject
            } else if let a = node as? NSMutableArray, let idx = Int(k), idx < a.count {
                node = a[idx] as AnyObject
            } else {
                throw MCPError.failed("键路径中间节点不是字典/数组: \(k)")
            }
        }
        guard let last = keys.last else { throw MCPError.invalidParams("key 不能为空") }
        if let d = node as? NSMutableDictionary {
            guard d[last] != nil else { throw MCPError.failed("键不存在: \(last)") }
            d.removeObject(forKey: last)
        } else if let a = node as? NSMutableArray, let idx = Int(last), idx < a.count {
            a.removeObject(at: idx)
        } else {
            throw MCPError.failed("键路径末端不是字典/数组: \(last)")
        }
    }
}

// MARK: - App 容器路径定位

final class FSContainerTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.container",
        summary: "按 bundle_id 返回 App 的完整路径四件套：数据容器、Bundle 目录、Documents、Library、Caches、tmp。AI 定位文件先调它，替代盲目 fs.find。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bid) else {
            return ["error": "未找到 App: \(bid)"]
        }
        var out: [String: Any] = [
            "bundle_id": app.bundleId,
            "name": app.name
        ]
        if !app.path.isEmpty { out["bundle_path"] = app.path }
        if let c = app.containerPath {
            out["container_path"] = c
            out["documents"] = c + "/Documents"
            out["library"] = c + "/Library"
            out["library_caches"] = c + "/Library/Caches"
            out["library_preferences"] = c + "/Library/Preferences"
            out["tmp"] = c + "/tmp"
        }
        out["hint"] = "读取用 fs.tree/fs.read；修改用 fs.write/fs.edit/fs.plist（仅容器内可写）"
        return out
    }
}

// MARK: - 崩溃日志解析

final class FSCrashTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.crash",
        summary: "读取设备崩溃日志（/var/mobile/Library/Logs/CrashReporter）并解析摘要：异常类型/终止原因/触发线程/栈顶帧。可按 bundle_id 过滤最近崩溃，用于诊断启动闪退。",
        parameters: [
            "bundle_id": "按进程名或 Bundle ID 过滤（可选）",
            "limit": "返回最近崩溃条数（默认 3，最大 10）",
            "dir": "崩溃日志目录（默认系统 CrashReporter）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let dir = (params["dir"] as? String) ?? "/var/mobile/Library/Logs/CrashReporter"
        guard FSPolicy.isAllowed(dir) else { throw MCPError.failed("路径不在可访问范围: \(dir)") }
        let limit = min(max((params["limit"] as? Int) ?? 3, 1), 10)
        let filter = (params["bundle_id"] as? String)?.lowercased() ?? ""
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            return ["error": "无法读取崩溃目录（TrollStore 环境可能无系统日志权限）: \(dir)"]
        }
        var candidates: [(path: String, mtime: Date)] = []
        for f in files {
            let ext = (f as NSString).pathExtension.lowercased()
            guard ext == "ips" || ext == "crash" else { continue }
            let full = (dir as NSString).appendingPathComponent(f)
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let m = attrs[.modificationDate] as? Date {
                candidates.append((full, m))
            }
        }
        candidates.sort { $0.mtime > $1.mtime }
        var results: [[String: Any]] = []
        for c in candidates.prefix(limit) {
            guard let text = try? String(contentsOfFile: c.path, encoding: .utf8) else { continue }
            let parsed = Self.parse(text, path: c.path)
            if !filter.isEmpty {
                let hay = (parsed["process"] as? String ?? "").lowercased() + " " + (parsed["bundle_id"] as? String ?? "").lowercased()
                guard hay.contains(filter) else { continue }
            }
            results.append(parsed)
        }
        return ["dir": dir, "found": files.count, "crashes": results, "crash_count": results.count]
    }

    private static func parse(_ text: String, path: String) -> [String: Any] {
        var out: [String: Any] = ["file": path]
        let lines = text.components(separatedBy: "
")
        // .ips：第一行元数据 JSON，第二行 body JSON
        if lines.count >= 2,
           let meta = Self.json(lines[0]),
           let body = Self.json(lines[1]) {
            out["format"] = "ips"
            if let pn = meta["procName"] as? String { out["process"] = pn }
            if let bid = meta["bundleID"] as? String { out["bundle_id"] = bid }
            if let ct = meta["captureTime"] as? String { out["capture_time"] = ct }
            if let ver = meta["appVersion"] as? String { out["app_version"] = ver }
            if let ex = body["exception"] as? [String: Any] {
                if let t = ex["type"] as? String { out["exception_type"] = t }
                if let s = ex["signal"] as? String { out["signal"] = s }
            }
            if let term = body["termination"] as? [String: Any] {
                if let r = term["reason"] as? String { out["termination_reason"] = r }
                if let i = term["indicator"] as? String { out["indicator"] = i }
            }
            if let ft = body["faultingThread"] as? Int,
               let threads = body["threads"] as? [[String: Any]],
               ft >= 0, ft < threads.count,
               let frames = threads[ft]["frames"] as? [[String: Any]] {
                out["faulting_thread"] = ft
                var top: [String] = []
                for f in frames.prefix(6) {
                    if let sym = f["symbol"] as? String { top.append(sym) }
                    else if let img = f["imageIndex"] { top.append("image\(img)") }
                }
                if !top.isEmpty { out["stack_top"] = top }
            }
            return out
        }
        // 老 .crash 文本格式
        out["format"] = "crash"
        let pairs: [(String, String)] = [
            ("Process:", "process"), ("Bundle Identifier:", "bundle_id"),
            ("Exception Type:", "exception_type"), ("Exception Codes:", "exception_codes"),
            ("Termination Reason:", "termination_reason"), ("Triggered by Thread:", "triggered_by_thread"),
            ("Version:", "app_version")
        ]
        for (needle, key) in pairs {
            if let l = lines.first(where: { $0.hasPrefix(needle) }) {
                out[key] = l.replacingOccurrences(of: needle, with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        var stack: [String] = []
        var inThread = false
        for l in lines {
            if l.hasPrefix("Thread ") { inThread = true }
            if l.hasPrefix("Thread ") && l.contains("Crashed") { inThread = true }
            if inThread {
                if l.hasPrefix("Thread ") && !l.contains("Crashed") && !stack.isEmpty { break }
                if l.contains("frame #") {
                    let parts = l.components(separatedBy: "  ").filter { !$0.isEmpty }
                    if parts.count >= 3 { stack.append(parts[2].trimmingCharacters(in: .whitespaces)) }
                }
                if stack.count >= 6 { break }
            }
        }
        if !stack.isEmpty { out["stack_top"] = stack }
        return out
    }

    private static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }
}

// MARK: - 图片元数据

final class FSImageInfoTool: MCPTool {
    let definition = ToolDefinition(
        name: "fs.image_info",
        summary: "图片元数据：格式/宽高/大小（PNG/JPEG/GIF/WebP）。识别后如需查看内容，用模型的视觉能力或截图工具。",
        parameters: [
            "path": "图片绝对路径（或工作区相对路径）",
            "bundle_id": "目标 App Bundle ID（填了则读该 App 数据容器）",
            "relative": "容器内相对路径（bundle_id 模式下用）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        var target: String? = nil
        if let p = FSPolicy.resolve(bundleId: bundleId, relative: rel, path: path) {
            target = p
        } else if let p = path, !p.isEmpty {
            target = p.hasPrefix("/") ? p : FSPolicy.workspace() + "/" + p
        }
        guard let p = target else { throw MCPError.invalidParams("需要 path 或 bundle_id+relative") }
        guard FSPolicy.isAllowed(p) else { throw MCPError.failed("路径不在可访问范围: \(p)") }
        let fm = FileManager.default
        guard let data = fm.contents(atPath: p) else { return ["error": "读取失败: \(p)"] }
        var out: [String: Any] = ["path": p, "size": data.count]
        let b = [UInt8](data.prefix(64))
        func be16(_ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o+1]) }
        func be32(_ o: Int) -> Int { (Int(b[o]) << 24) | (Int(b[o+1]) << 16) | (Int(b[o+2]) << 8) | Int(b[o+3]) }
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            out["format"] = "png"; out["width"] = be32(16); out["height"] = be32(20)
        } else if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 {
            out["format"] = "jpeg"
            var o = 2
            while o + 9 < b.count {
                if b[o] == 0xFF, (b[o+1] & 0xF0) == 0xC0, (b[o+1] & 0x0F) >= 0x01, (b[o+1] & 0x0F) <= 0x03 {
                    out["height"] = be16(o + 5); out["width"] = be16(o + 7); break
                }
                if b[o] == 0xFF { o += 2 + Int(b[o+1]) << 8 | Int(b[o+2]) } else { o += 1 }
            }
        } else if b.count >= 10, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 {
            out["format"] = "gif"
            out["width"] = Int(b[6]) | Int(b[7]) << 8
            out["height"] = Int(b[8]) | Int(b[9]) << 8
        } else if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            out["format"] = "webp"
            let fourcc = String(bytes: b[12...15], encoding: .ascii) ?? ""
            if fourcc == "VP8X", b.count >= 30 {
                let w = Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16
                let h = Int(b[27]) | Int(b[28]) << 8 | Int(b[29]) << 16
                out["width"] = w + 1; out["height"] = h + 1
            } else if fourcc == "VP8L", b.count >= 25 {
                let bits = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
                out["width"] = (bits & 0x3FFF) + 1; out["height"] = ((bits >> 14) & 0x3FFF) + 1
            } else if fourcc == "VP8 ", b.count >= 30 {
                out["width"] = be16(26) & 0x3FFF; out["height"] = be16(28) & 0x3FFF
            }
        } else {
            out["format"] = "unknown"
            out["hint"] = "不是常见图片格式（PNG/JPEG/GIF/WebP），用 fs.hexdump 查看 magic"
        }
        out["hint"] = "需要看图内容时用模型的视觉能力查看"
        return out
    }
}
