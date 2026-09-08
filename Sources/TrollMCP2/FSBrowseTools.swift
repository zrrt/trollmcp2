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
            "as": "强制格式：auto（默认）/ text / json / hex"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String
        let rel = params["relative"] as? String
        let path = params["path"] as? String
        let force = (params["as"] as? String) ?? "auto"
        let maxBytes = max((params["max_bytes"] as? Int) ?? 524288, 0)

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
        // 3) 文本（UTF-8 优先，UTF-16 BOM）
        if force == "text" || force == "auto" {
            if let str = String(data: slice, encoding: .utf8), !str.contains("\u{FFFD}") {
                result["kind"] = "text"
                result["encoding"] = "utf-8"
                result["content"] = str
                return result
            }
            if slice.count >= 2, slice[0] == 0xFF, slice[1] == 0xFE,
               let str = String(data: slice, encoding: .utf16LittleEndian) {
                result["kind"] = "text"
                result["encoding"] = "utf-16le"
                result["content"] = str
                return result
            }
            if slice.count >= 2, slice[0] == 0xFE, slice[1] == 0xFF,
               let str = String(data: slice, encoding: .utf16BigEndian) {
                result["kind"] = "text"
                result["encoding"] = "utf-16be"
                result["content"] = str
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
