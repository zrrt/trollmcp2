import Foundation

// MARK: - v2.9.141 跨 App 数据桥（沙箱破坏者）
// 通行证：no-sandbox + AppDataContainers 权限 → 可读写任意 App 的 Bundle/数据容器
// 容器定位：解析 /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist
//（与 TrollFools/Residue 同法，纯文件操作无私有 API 依赖）

enum AppContainer {
    /// 数据容器路径（bundle_id → /var/mobile/Containers/Data/Application/<UUID>）
    static func dataContainer(for bundleId: String) -> String? {
        let root = "/var/mobile/Containers/Data/Application"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for uuid in entries where uuid.count == 36 {
            let meta = root + "/" + uuid + "/.com.apple.mobile_container_manager.metadata.plist"
            guard let dict = NSDictionary(contentsOfFile: meta),
                  let bid = dict["MCMMetadataIdentifier"] as? String, bid == bundleId else { continue }
            return root + "/" + uuid
        }
        return nil
    }

    /// Bundle 路径（走 AppCatalog 缓存枚举）
    static func bundlePath(for bundleId: String) -> String? {
        AppCatalog.list().first { $0.bundleId == bundleId }?.path
    }

    /// 解析 scope 到实际路径
    static func resolve(bundleId: String, scope: String, path: String) -> (ok: Bool, full: String?, reason: String) {
        let root: String
        if scope == "bundle" {
            guard let bp = bundlePath(for: bundleId) else {
                return (false, nil, "找不到 App bundle（确认 bundle_id 正确）")
            }
            root = bp
        } else if scope == "data" {
            guard let dp = dataContainer(for: bundleId) else {
                return (false, nil, "找不到数据容器（App 可能未运行过或已卸载）")
            }
            root = dp
        } else {
            return (false, nil, "scope 仅支持 bundle/data")
        }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let full = root + (cleaned.isEmpty ? "" : "/" + cleaned)
        // 防越界：禁止逃出容器根
        guard full.hasPrefix(root + "/") || full == root else {
            return (false, nil, "路径越界（只能访问容器内）")
        }
        return (true, full, "")
    }

    /// 目录大小
    static func size(of path: String) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let p as String in enumerator {
                let full = path + "/" + p
                if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                   let size = attrs[.size] as? Int64 {
                    bytes += size
                }
                files += 1
            }
        }
        return (bytes, files)
    }

    static func human(_ b: Int64) -> String {
        let f = Double(b)
        if f >= 1_073_741_824 { return String(format: "%.2f GB", f / 1_073_741_824) }
        if f >= 1_048_576 { return String(format: "%.2f MB", f / 1_048_576) }
        if f >= 1024 { return String(format: "%.1f KB", f / 1024) }
        return "\(b) B"
    }
}

// MARK: - MCP 工具

final class BridgeContainerTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.container",
        summary: "查任意 App 的 Bundle 路径 + 数据容器路径 + 容器大小（跨 App 数据桥的基础）。",
        parameters: ["bundle_id": "Target App bundle_id"], verified: true, category: "filesystem")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let bp = AppContainer.bundlePath(for: bid)
        let dp = AppContainer.dataContainer(for: bid)
        var out: [String: Any] = ["bundle_id": bid, "bundle_path": bp ?? "", "data_container": dp ?? ""]
        if let bp = bp {
            let s = AppContainer.size(of: bp)
            out["bundle_size"] = AppContainer.human(s.bytes)
            out["bundle_files"] = s.files
        }
        if let dp = dp {
            let s = AppContainer.size(of: dp)
            out["data_size"] = AppContainer.human(s.bytes)
            out["data_files"] = s.files
        }
        return out
    }
}

final class BridgeLsTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.ls",
        summary: "列出任意 App 容器内的目录（bundle=安装包目录 / data=数据容器）。",
        parameters: ["bundle_id": "Target App bundle_id", "scope": "bundle or data (default data)", "path": "Relative path inside container (default root)"], verified: true, category: "filesystem")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let scope = params["scope"] as? String ?? "data"
        let path = params["path"] as? String ?? ""
        let r = AppContainer.resolve(bundleId: bid, scope: scope, path: path)
        guard r.ok, let full = r.full else { throw MCPError.failed(r.reason) }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: full) else {
            throw MCPError.failed("无法读取目录（\(full)）")
        }
        var entries: [[String: Any]] = []
        for name in items {
            let fp = full + "/" + name
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fp, isDirectory: &isDir)
            let attrs = try? FileManager.default.attributesOfItem(atPath: fp)
            entries.append([
                "name": name,
                "type": isDir.boolValue ? "dir" : "file",
                "size": (attrs?[.size] as? Int64) ?? 0
            ])
        }
        entries.sort { ($0["type"] as? String ?? "") == ($1["type"] as? String ?? "") && ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        return ["bundle_id": bid, "scope": scope, "path": full, "items": entries]
    }
}

final class BridgeReadTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.read",
        summary: "读取任意 App 容器内文件（文本/plist/JSON，>4000 字符截断；二进制请用 fs.hexdump）。",
        parameters: ["bundle_id": "Target App bundle_id", "scope": "bundle or data", "path": "Relative path inside container"], verified: true, category: "filesystem")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let scope = params["scope"] as? String ?? "data"
        let path = params["path"] as? String ?? ""
        let r = AppContainer.resolve(bundleId: bid, scope: scope, path: path)
        guard r.ok, let full = r.full else { throw MCPError.failed(r.reason) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else {
            throw MCPError.failed("目标不是文件（\(full)）")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else {
            throw MCPError.failed("读取失败（\(full)）")
        }
        // plist → JSON 文本
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           JSONSerialization.isValidJSONObject(plist),
           let jdata = try? JSONSerialization.data(withJSONObject: plist, options: [.prettyPrinted, .sortedKeys]) {
            var text = String(data: jdata, encoding: .utf8) ?? ""
            let truncated = text.count > 4000
            if truncated { text = String(text.prefix(4000)) + "\n…[已截断]…" }
            return ["path": full, "kind": "plist/json", "content": text, "truncated": truncated]
        }
        if let text = String(data: data, encoding: .utf8) {
            let truncated = text.count > 4000
            let shown = truncated ? String(text.prefix(4000)) + "\n…[已截断]…" : text
            return ["path": full, "kind": "text", "content": shown, "truncated": truncated]
        }
        return ["path": full, "kind": "binary", "size": data.count, "hint": "二进制文件，请用 fs.hexdump 查看"]
    }
}

final class BridgeCopyTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.copy",
        summary: "跨 App 容器复制文件/目录（A 的容器 → B 的容器，或 → 工作区）。写操作前请确认不破坏目标数据。",
        parameters: ["from_bundle": "Source App bundle_id", "from_scope": "Source scope", "from_path": "Source relative path", "to_bundle": "Target App bundle_id (use workspace for workspace)", "to_scope": "Target scope", "to_path": "Target relative path"], verified: true, category: "filesystem")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let fb = params["from_bundle"] as? String, !fb.isEmpty,
              let fs = params["from_scope"] as? String else {
            throw MCPError.invalidParams("from_bundle, from_scope required")
        }
        let fp = params["from_path"] as? String ?? ""
        let tb = params["to_bundle"] as? String ?? "workspace"
        let ts = params["to_scope"] as? String ?? ""
        let tp = params["to_path"] as? String ?? ""

        let srcR = AppContainer.resolve(bundleId: fb, scope: fs, path: fp)
        guard srcR.ok, let src = srcR.full else { throw MCPError.failed(srcR.reason) }
        guard FileManager.default.fileExists(atPath: src) else { throw MCPError.failed("源不存在（\(src)）") }

        let dst: String
        if tb == "workspace" {
            dst = Workspace.root.appendingPathComponent("bridge_exports").path + "/" + tp
        } else {
            guard !ts.isEmpty else { throw MCPError.invalidParams("to_scope required（workspace 目标除外）") }
            let dstR = AppContainer.resolve(bundleId: tb, scope: ts, path: tp)
            guard dstR.ok, let d = dstR.full else { throw MCPError.failed(dstR.reason) }
            dst = d
        }
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: dst).deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst) {
                try FileManager.default.removeItem(atPath: dst)
            }
            try FileManager.default.copyItem(atPath: src, toPath: dst)
            let size = AppContainer.size(of: dst)
            return ["message": "已复制 \(src) → \(dst)", "src": src, "dst": dst, "size": AppContainer.human(size.bytes)]
        } catch {
            throw MCPError.failed("复制失败: \(error.localizedDescription)")
        }
    }
}

final class BridgeExportTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.export",
        summary: "导出任意 App 容器文件/目录到工作区（默认 bridge_exports/<bundle_id>/），用于备份/迁移。",
        parameters: ["bundle_id": "Target App bundle_id", "scope": "bundle or data", "path": "Relative path (default root = whole container)"], verified: true, category: "filesystem")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let scope = params["scope"] as? String ?? "data"
        let path = params["path"] as? String ?? ""
        let r = AppContainer.resolve(bundleId: bid, scope: scope, path: path)
        guard r.ok, let full = r.full else { throw MCPError.failed(r.reason) }
        guard FileManager.default.fileExists(atPath: full) else { throw MCPError.failed("路径不存在（\(full)）") }

        let base = Workspace.root.appendingPathComponent("bridge_exports").appendingPathComponent(bid).path
        let rel = path.isEmpty ? "root" : path.replacingOccurrences(of: "/", with: "_")
        let dst = base + "/" + rel
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: dst).deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst) { try FileManager.default.removeItem(atPath: dst) }
            try FileManager.default.copyItem(atPath: full, toPath: dst)
            let size = AppContainer.size(of: dst)
            return ["message": "已导出到工作区", "src": full, "dst": dst, "size": AppContainer.human(size.bytes), "files": size.files]
        } catch {
            throw MCPError.failed("导出失败: \(error.localizedDescription)")
        }
    }
}

final class BridgeImportTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.import",
        summary: "从工作区导入文件/目录到任意 App 容器（恢复/迁移）。写操作高风险，确认目标数据可覆盖。",
        parameters: ["src_path": "Source path inside workspace", "bundle_id": "Target App bundle_id", "scope": "bundle or data", "to_path": "Target relative path inside container"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let src = params["src_path"] as? String, !src.isEmpty,
              let bid = params["bundle_id"] as? String, !bid.isEmpty,
              let scope = params["scope"] as? String else {
            throw MCPError.invalidParams("src_path, bundle_id, scope required")
        }
        let to = params["to_path"] as? String ?? ""
        let srcFull: String
        if src.hasPrefix("/") {
            srcFull = src
        } else {
            srcFull = Workspace.root.appendingPathComponent(src).path
        }
        guard FileManager.default.fileExists(atPath: srcFull) else { throw MCPError.failed("源不存在（\(srcFull)）") }
        let r = AppContainer.resolve(bundleId: bid, scope: scope, path: to)
        guard r.ok, let dst = r.full else { throw MCPError.failed(r.reason) }
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: dst).deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst) { try FileManager.default.removeItem(atPath: dst) }
            try FileManager.default.copyItem(atPath: srcFull, toPath: dst)
            return ["message": "已导入 \(srcFull) → \(dst)", "src": srcFull, "dst": dst]
        } catch {
            throw MCPError.failed("导入失败: \(error.localizedDescription)")
        }
    }
}
