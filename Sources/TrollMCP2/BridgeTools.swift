import Foundation

// MARK: - v2.9.141 跨 App 数据桥 (沙箱破坏者）
// 通行证：no-sandbox + AppDataContainers 权限 → 可读写任意 App 的 Bundle/数据容器
// 容器定位：解析 /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist
// (与 TrollFools/Residue 同法，纯文件操作无私有 API 依赖）

enum AppContainer {
    /// 数据容器路径 (bundle_id → /var/mobile/Containers/Data/Application/<UUID>）
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

    /// Bundle 路径 (走 AppCatalog 缓存枚举）
    static func bundlePath(for bundleId: String) -> String? {
        AppCatalog.list().first { $0.bundleId == bundleId }?.path
    }

    /// 解析 scope 到实际路径
    static func resolve(bundleId: String, scope: String, path: String) -> (ok: Bool, full: String?, reason: String) {
        let root: String
        if scope == "bundle" {
            guard let bp = bundlePath(for: bundleId) else {
                return (false, nil, "App bundle not found (confirm bundle_id)")
            }
            root = bp
        } else if scope == "data" {
            guard let dp = dataContainer(for: bundleId) else {
                return (false, nil, "data container not found (App may never have run or is uninstalled)")
            }
            root = dp
        } else {
            return (false, nil, "scope only supports bundle/data")
        }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let full = root + (cleaned.isEmpty ? "" : "/" + cleaned)
        // 防越界：禁止逃出容器根
        guard full.hasPrefix(root + "/") || full == root else {
            return (false, nil, "path out of bounds (container access only)")
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
        summary: "Get an app's container paths. Use for: find where an app's data is stored, cross-app data operations. Don't use for: list files inside container (use bridge.ls), read file (use bridge.read). Example: user says 'where is 小红书 data stored' → get container paths.",
        parameters: ["bundle_id": "Target app bundle ID"], verified: true, category: "filesystem")
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
        summary: "List files inside any app's container. Use for: browse another app's data files. Don't use for: list files in your own workspace (use fs.tree), read file content (use bridge.read). Example: user says 'see what is in 小红书 Documents' → list directory.",
        parameters: ["bundle_id": "Target app bundle ID", "scope": "bundle or data (default: data)", "path": "Relative path inside container (default: root)"], verified: true, category: "filesystem")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let scope = params["scope"] as? String ?? "data"
        let path = params["path"] as? String ?? ""
        let r = AppContainer.resolve(bundleId: bid, scope: scope, path: path)
        guard r.ok, let full = r.full else { throw MCPError.failed(r.reason) }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: full) else {
            throw MCPError.failed("cannot read directory (\(full))")
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
        summary: "Read a file from another app's container. Use for: read another app's text/plist/JSON files. Don't use for: read binary files (use fs.hexdump), list directory (use bridge.ls). Example: user says 'read 小红书 user.plist' → read file.",
        parameters: ["bundle_id": "Target app bundle ID", "scope": "bundle or data", "path": "Relative path inside container"], verified: true, category: "filesystem")
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
            throw MCPError.failed("target is not a file (\(full))")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else {
            throw MCPError.failed("read failed (\(full))")
        }
        // plist → JSON 文本
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           JSONSerialization.isValidJSONObject(plist),
           let jdata = try? JSONSerialization.data(withJSONObject: plist, options: [.prettyPrinted, .sortedKeys]) {
            var text = String(data: jdata, encoding: .utf8) ?? ""
            let truncated = text.count > 4000
            if truncated { text = String(text.prefix(4000)) + "\n...[truncated]..." }
            return ["path": full, "kind": "plist/json", "content": text, "truncated": truncated]
        }
        if let text = String(data: data, encoding: .utf8) {
            let truncated = text.count > 4000
            let shown = truncated ? String(text.prefix(4000)) + "\n...[truncated]..." : text
            return ["path": full, "kind": "text", "content": shown, "truncated": truncated]
        }
        return ["path": full, "kind": "binary", "size": data.count, "hint": "binary file, use fs.hexdump to view"]
    }
}

final class BridgeCopyTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.copy",
        summary: "Copy files between app containers. Use for: transfer data from one app to another, export to workspace. Don't use for: copy within workspace (use fs.copy), list files (use bridge.ls). Example: user says 'copy 小红书 chat records out' → copy file.",
        parameters: ["from_bundle": "Source app bundle ID", "from_scope": "Source scope", "from_path": "Source path", "to_bundle": "Target app bundle ID (or 'workspace')", "to_scope": "Target scope", "to_path": "Target path"], verified: true, category: "filesystem")
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
        guard FileManager.default.fileExists(atPath: src) else { throw MCPError.failed("source does not exist (\(src))") }

        let dst: String
        if tb == "workspace" {
            dst = Workspace.root.appendingPathComponent("bridge_exports").path + "/" + tp
        } else {
            guard !ts.isEmpty else { throw MCPError.invalidParams("to_scope required (unless target is workspace)") }
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
            return ["message": "copied \(src) -> \(dst)", "src": src, "dst": dst, "size": AppContainer.human(size.bytes)]
        } catch {
            throw MCPError.failed("copy failed: \(error.localizedDescription)")
        }
    }
}

final class BridgeExportTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.export",
        summary: "Export files from an app container to workspace. Use for: backup app data, migrate to another app. Don't use for: read file content (use bridge.read), copy between apps (use bridge.copy). Example: user says 'export 小红书 data for backup' → export.",
        parameters: ["bundle_id": "Target app bundle ID", "scope": "bundle or data", "path": "Relative path (default: root = whole container)"], verified: true, category: "filesystem")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let scope = params["scope"] as? String ?? "data"
        let path = params["path"] as? String ?? ""
        let r = AppContainer.resolve(bundleId: bid, scope: scope, path: path)
        guard r.ok, let full = r.full else { throw MCPError.failed(r.reason) }
        guard FileManager.default.fileExists(atPath: full) else { throw MCPError.failed("path does not exist (\(full))") }

        let base = Workspace.root.appendingPathComponent("bridge_exports").appendingPathComponent(bid).path
        let rel = path.isEmpty ? "root" : path.replacingOccurrences(of: "/", with: "_")
        let dst = base + "/" + rel
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: dst).deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst) { try FileManager.default.removeItem(atPath: dst) }
            try FileManager.default.copyItem(atPath: full, toPath: dst)
            let size = AppContainer.size(of: dst)
            return ["message": "exported to workspace", "src": full, "dst": dst, "size": AppContainer.human(size.bytes), "files": size.files]
        } catch {
            throw MCPError.failed("export failed: \(error.localizedDescription)")
        }
    }
}

final class BridgeImportTool: MCPTool {
    let definition = ToolDefinition(name: "bridge.import",
        summary: "Import files from workspace into an app container. Use for: restore app data, migrate data from another app. Don't use for: export from app (use bridge.export), copy between apps (use bridge.copy). Warning: high-risk write, may overwrite app data. Example: user says 'import backed-up data into 小红书' → import.",
        parameters: ["src_path": "Source path in workspace", "bundle_id": "Target app bundle ID", "scope": "bundle or data", "to_path": "Target path inside container"])
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
        guard FileManager.default.fileExists(atPath: srcFull) else { throw MCPError.failed("source does not exist (\(srcFull))") }
        let r = AppContainer.resolve(bundleId: bid, scope: scope, path: to)
        guard r.ok, let dst = r.full else { throw MCPError.failed(r.reason) }
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: dst).deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst) { try FileManager.default.removeItem(atPath: dst) }
            try FileManager.default.copyItem(atPath: srcFull, toPath: dst)
            return ["message": "imported \(srcFull) -> \(dst)", "src": srcFull, "dst": dst]
        } catch {
            throw MCPError.failed("import failed: \(error.localizedDescription)")
        }
    }
}
