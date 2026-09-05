import Foundation
import UIKit

// MARK: - 文件桥（对齐原版 artifact.* 工具）

final class ArtifactReadTextTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.read_text",
        summary: "读取工作区内文件的文本内容",
        parameters: ["path": "工作区内相对路径"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        let url = try Workspace.resolve(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        return ["content": text]
    }
}

final class ArtifactWriteTextTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.write_text",
        summary: "向工作区写入文本文件（覆盖）",
        parameters: ["path": "工作区内相对路径", "content": "文本内容"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String,
              let content = params["content"] as? String else {
            throw MCPError.invalidParams("path and content required")
        }
        let url = try Workspace.resolve(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        return ["written": true, "bytes": content.utf8.count]
    }
}

final class ArtifactListTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.list",
        summary: "列出工作区目录内容（若路径是文件则返回该文件信息，不报错）",
        parameters: ["subpath": "可选子目录或文件路径"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let sub = params["subpath"] as? String ?? ""
        let dir = try Workspace.resolve(sub)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            return ["entries": [], "error": "路径不存在: \(sub)"]
        }
        // v2.9.33：subpath 是文件时返回该文件信息（修复 AI 列 .deb 文件报 Not a directory）
        if !isDir.boolValue {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return ["entries": [
                ["name": dir.lastPathComponent,
                 "path": dir.path,
                 "isDirectory": false,
                 "size": size,
                 "hint": "这是文件不是目录；如需读取其内容请用 artifact.read_text（文本）或查看下载目录中的同名裸 dylib"]
            ]]
        }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // v2.9.33：标注类型，AI 可区分文件/目录
        let entries = items.map { name -> [String: Any] in
            var isD: ObjCBool = false
            let p = (dir.path as NSString).appendingPathComponent(name)
            _ = FileManager.default.fileExists(atPath: p, isDirectory: &isD)
            return ["name": name, "path": p, "isDirectory": isD.boolValue]
        }
        return ["entries": entries]
    }
}

// MARK: - v2.9.33 递归查找工具

/// 递归扫描工作区，按文件名/扩展名查找文件（如 .dylib / .deb），
/// 帮 AI 快速定位 GitHub 下载产物中的注入源 dylib（Theos 打包的裸 dylib 在
/// downloads/run_*/private/.theos/obj/debug/ 下，.deb 是归档包不是目录）。
final class ArtifactFindTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.find",
        summary: "递归查找工作区文件：按扩展名（如 dylib、deb）或文件名片段搜索，返回路径与大小。下载的编译产物用它定位注入源。",
        parameters: ["ext": "扩展名（不带点，如 dylib/deb/ipa）", "name": "文件名包含片段（可选）", "max_depth": "最大递归深度（默认 8）", "limit": "最多返回条数（默认 20）"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let ext = (params["ext"] as? String ?? "").lowercased()
        let nameFrag = (params["name"] as? String ?? "").lowercased()
        let maxDepth = (params["max_depth"] as? NSNumber)?.intValue ?? 8
        let limit = (params["limit"] as? NSNumber)?.intValue ?? 20
        var results: [[String: Any]] = []
        var skipped: [String] = []

        let root = Workspace.root.path
        func walk(_ dir: String, _ depth: Int) {
            guard depth <= maxDepth, results.count < limit else { return }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for item in items {
                let p = (dir as NSString).appendingPathComponent(item)
                var isD: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isD) else { continue }
                if isD.boolValue {
                    // 跳过无意义目录
                    if item == ".git" || item == "node_modules" { continue }
                    walk(p, depth + 1)
                } else {
                    let lower = item.lowercased()
                    var hit = true
                    if !ext.isEmpty, !lower.hasSuffix("." + ext) { hit = false }
                    if hit, !nameFrag.isEmpty, !lower.contains(nameFrag) { hit = false }
                    if hit {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: p)
                        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        results.append(["name": item, "path": p, "size": size])
                        if results.count >= limit { return }
                    }
                }
            }
        }
        walk(root, 0)
        skipped = results.count >= limit ? ["达到 limit=\(limit)，可用更精确的 ext/name 缩小范围"] : []
        return [
            "query": ["ext": ext, "name": nameFrag],
            "total": results.count,
            "matches": results,
            "hint": "Theos 编译产物通常同时产出裸 dylib（.../.theos/obj/debug/xxx.dylib）与归档 .deb；注入时用裸 dylib 路径传给 injection.enable 的 dylib_path。",
            "note": skipped
        ]
    }
}

// MARK: - 基础工具

final class PingTool: MCPTool {
    let definition = ToolDefinition(name: "ping", summary: "连通性测试")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        ["pong": true, "ts": Int(Date().timeIntervalSince1970)]
    }
}

final class DeviceInfoTool: MCPTool {
    let definition = ToolDefinition(name: "device.info", summary: "设备与应用信息")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "system": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "model": UIDevice.current.model,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-",
            "workspace": Workspace.root.path,
        ]
    }
}

final class DeviceProbeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.probe",
        summary: "检测本机环境：TrollStore/TrollFools、task_for_pid、App 容器读写、注入二进制、amfid 绕过推断")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let r = DeviceProbe.shared.run()
        return [
            "device": [
                "name": r.deviceName,
                "model": r.model,
                "systemVersion": r.systemVersion,
                "vendorID": r.vendorID,
            ],
            "trollStore": r.trollStore,
            "trollFools": r.trollFools,
            "task_for_pid": r.taskForPid,
            "appContainerWrite": r.containerWrite,
            "injectionBinaries": r.injectionBinaries,
            "amfidBypassInferred": r.amfidBypassInferred,
            "entitlementsOK": r.entitlementsOK,
            "rootDiagnosis": r.rootDiagnosis ?? [:],
            "ready": r.ready,
            "checks": r.checks.map { ["label": $0.label, "passed": $0.passed, "detail": $0.detail] },
        ]
    }
}
