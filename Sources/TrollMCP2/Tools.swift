import Foundation
import UIKit

// MARK: - 文件桥（对齐原版 artifact.* 工具）

final class ArtifactReadTextTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.read_text",
        summary: "Read a text file from the workspace. Use for: read files you created or downloaded. Don't use for: browse directory (use fs.tree), read app container files (use fs.read with bundle_id). Example: user says '读一下那个报告' → read text file from workspace.",
        parameters: ["path": "File path relative to workspace (e.g. reports/data.txt)"], verified: true, category: "filesystem")

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
        summary: "Write a text file to the workspace. Use for: create new file, save text results. Don't use for: write to app container (use container.write_text), edit existing file (use fs.edit). Example: user says '把这个结果保存成文件' → write to workspace.",
        parameters: ["path": "File path", "content": "File content"]
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
        summary: "List files in the workspace directory. Use for: see what files are in workspace, browse downloaded files. Don't use for: browse app container files (use fs.tree), read file content (use fs.read). Example: user says 'workspace 里有什么文件' → list artifacts.",
    verified: true, category: "filesystem")

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
        // v2.9.68：限制最多 50 条，避免目录文件多时上下文爆炸
        let limited = Array(entries.prefix(50))
        return ["entries": limited, "total": entries.count, "truncated": entries.count > 50, "hint": entries.count > 50 ? "目录有 \(entries.count) 项，仅返回前 50 项；用 artifact.find 按名称/扩展名精确搜索" : ""]
    }
}

// MARK: - v2.9.33 递归查找工具

/// 递归扫描工作区，按文件名/扩展名查找文件（如 .dylib / .deb），
/// 帮 AI 快速定位 GitHub 下载产物中的注入源 dylib（Theos 打包的裸 dylib 在
/// downloads/run_*/private/.theos/obj/debug/ 下，.deb 是归档包不是目录）。
final class ArtifactFindTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.find",
        summary: "Find files in workspace by name or extension. Use for: locate a specific file (e.g. find all .ipa files). Don't use for: list directory (use artifact.list), search file contents (use fs.grep). Example: user says 'workspace 里的 IPA 文件在哪' → find by extension.",
    verified: true, category: "filesystem")

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
    let definition = ToolDefinition(name: "ping", summary: "Connectivity test. Use for: check if TrollAgent is responsive. Don't use for: check network connectivity (use shell.exec ping), check device info (use device.info). Example: user says '你还在吗' → ping test.",
        parameters: [:])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        ["pong": true, "ts": Int(Date().timeIntervalSince1970)]
    }
}

final class DeviceInfoTool: MCPTool {
    let definition = ToolDefinition(name: "device.info", summary: "Get device info: iOS version, iPhone model, memory/storage, battery, TrollAgent version, workspace path. Use for: check what iOS version, know device specs, find workspace path. Don't use for: spoof/change device info (use device.fake), wipe keychain (use device.keychain_wipe). Example: user says '我手机什么型号' → get device info.", verified: true, category: "device")

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
        summary: "Probe/check device environment: TrollStore installed, can we inject, what permissions available. Use for: check if device supports injection, see what capabilities are available. Don't use for: get device specs (use device.info), check battery/memory (use device.snapshot). Example: user says '我手机能注入吗，环境怎么样' → probe device.",
        verified: true, category: "device")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let r = DeviceProbe.shared.run()
        // v2.9.125：CLI 式一句话结论（dispatch 取 message 放顶层）
        let failedChecks = r.checks.filter { !$0.passed }
        let message: String
        if r.ready {
            message = "环境就绪（TrollStore✓ 权限✓ 工具链✓）"
        } else {
            let labels = failedChecks.prefix(3).map { $0.label }.joined(separator: "、")
            message = "环境未就绪：\(labels.isEmpty ? "未知原因" : labels)"
        }
        return [
            "message": message,
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
            "issues": failedChecks.map { $0.label },
            "checks": r.checks.map { ["label": $0.label, "passed": $0.passed, "detail": $0.detail] },
        ]
    }
}

// MARK: - MemoryTweak（H5GG 式内存修改，通过注入的 dylib HTTP API 通信）

final class MemoryTweakTool: MCPTool {
    let definition = ToolDefinition(
        name: "memory",
        summary: "Game memory modification (like GameGuardian/H5GG). Use for: modify game values like coins, HP, lives, scores. Don't use for: read app files (use fs.read), network capture (use network.capture). Prerequisite: inject MemoryTweak.dylib into target game first. Workflow: 1) search for current value, 2) change value in game, 3) refine search, 4) write new value. Example: user says '改金币' → search coin count in game memory.",
        parameters: [
            "action": "search (first scan) / refine (filter results) / write (set new value) / freeze (lock value) / unfreeze / status / frozen (list locked values)",
            "value": "Value to search/write/freeze. e.g. 1000 coins, 50 HP",
            "type": "Data type: int (integer, default) / int64 / float (decimal) / double / byte / short",
            "address": "Memory address (0x hex format, required for write/freeze)"
        ]
    )

    private let port = 8765

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("action required")
        }

        let method: String
        let path: String
        var body: [String: Any] = [:]

        switch action {
        case "search":
            guard let value = params["value"] else { throw MCPError.invalidParams("value required for search") }
            method = "POST"; path = "/search"
            body = ["value": value, "type": params["type"] as? String ?? "int"]
        case "refine":
            guard let value = params["value"] else { throw MCPError.invalidParams("value required for refine") }
            method = "POST"; path = "/refine"
            body = ["value": value, "type": params["type"] as? String ?? "int"]
        case "write":
            guard let value = params["value"], let addr = params["address"] as? String else {
                throw MCPError.invalidParams("value and address required for write")
            }
            method = "POST"; path = "/write"
            body = ["value": value, "address": addr, "type": params["type"] as? String ?? "int"]
        case "freeze":
            guard let value = params["value"], let addr = params["address"] as? String else {
                throw MCPError.invalidParams("value and address required for freeze")
            }
            method = "POST"; path = "/freeze"
            body = ["value": value, "address": addr, "type": params["type"] as? String ?? "int"]
        case "unfreeze":
            guard let addr = params["address"] as? String else { throw MCPError.invalidParams("address required for unfreeze") }
            method = "POST"; path = "/unfreeze"
            body = ["address": addr]
        case "status":
            method = "GET"; path = "/status"
        case "frozen":
            method = "GET"; path = "/frozen"
        case "results":
            method = "GET"; path = "/results"
        default:
            throw MCPError.invalidParams("unknown action: \(action)")
        }

        return try httpRequest(method: method, path: path, body: body)
    }

    private func httpRequest(method: String, path: String, body: [String: Any]) throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        setHTTPMethod(method, on: &request)
        setTimeoutInterval(30, on: &request)

        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 35)

        if let error = resultError {
            return ["error": "连接 MemoryTweak 失败（\(error.localizedDescription)）。请确认 MemoryTweak.dylib 已注入目标App且目标App正在运行。", "connected": false]
        }
        guard let data = resultData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "解析响应失败", "connected": false]
        }
        return json
    }
}


// MARK: - v2.9.108 剪贴板工具（借鉴 ios-mcp 能力）
// AI 读取/写入系统剪贴板：读验证码/链接/token、把结果复制给用户粘贴

final class ClipboardReadTool: MCPTool {
    let definition = ToolDefinition(
        name: "clipboard.read",
        summary: "Read what's currently in the clipboard. Use for: get the last copied text, read verification code from clipboard. Don't use for: copy text to clipboard (use clipboard.write), save text to file (use artifact.write_text). Example: user says '剪贴板里复制了什么' → read clipboard.",
        parameters: [:],
        verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let text = UIThreadBridge.readClipboard()
        if text.isEmpty {
            return ["text": "", "empty": true, "hint": "剪贴板为空（无可读文本）"]
        }
        return ["text": text, "empty": false, "length": text.count]
    }
}

final class ClipboardWriteTool: MCPTool {
    let definition = ToolDefinition(
        name: "clipboard.write",
        summary: "Copy text to the clipboard. Use for: put text on clipboard so user can paste it elsewhere. Don't use for: read clipboard (use clipboard.read), save text to file (use artifact.write_text). Example: user says '把这段文字复制一下' → write to clipboard.",
        parameters: ["text": "Text to copy to clipboard (required)"],
    verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String, !text.isEmpty else {
            throw MCPError.invalidParams("text required")
        }
        UIThreadBridge.paste(text)
        return ["ok": true, "length": text.count]
    }
}

// MARK: - v3.1.39: artifact 大工具 + 子命令（合并 3 个 artifact.* 工具）

final class ArtifactExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact",
        summary: "Manage workspace files (read/write/list). Use subcommand to specify action. Use for: read/write/list files in workspace. Don't use for: read app container files (use fs.*), system files (use shell.exec). Example: read → artifact read filename:report.txt; list → artifact list. Subcommands: read / write / list.",
        parameters: [
            "command": "Subcommand: read / write / list",
            "filename": "File name (for read/write)",
            "text": "Text to write (for write)"
        ],
        verified: true, category: "fs")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("artifact", detail: command)
        
        switch command {
        case "read":
            guard let filename = params["filename"] as? String else {
                throw MCPError.invalidParams("filename required")
            }
            return try ArtifactReadTextTool().invoke(["filename": filename])
            
        case "write":
            guard let filename = params["filename"] as? String else {
                throw MCPError.invalidParams("filename required")
            }
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required")
            }
            return try ArtifactWriteTextTool().invoke(["filename": filename, "text": text])
            
        case "list":
            return try ArtifactListTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: read/write/list")
        }
    }
}

// MARK: - v3.1.40: device 大工具 + 子命令（合并 4 个 device.* 工具）

final class DeviceExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "device",
        summary: "Manage device info and spoofing (info/probe/fake/restore). Use subcommand to specify action. Use for: get device info, spoof device identity. Don't use for: app management (use app.*), injection (use inject.*). Example: info → device info; fake → device fake. Subcommands: info / probe / fake / restore.",
        parameters: [
            "command": "Subcommand: info / probe / fake / restore"
        ],
        verified: true, category: "device")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("device", detail: command)
        
        switch command {
        case "info":
            return try DeviceInfoTool().invoke([:])
            
        case "probe":
            return try DeviceProbeTool().invoke([:])
            
        case "fake":
            return try DeviceFakeTool().invoke([:])
            
        case "restore":
            return try DeviceRestoreTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: info/probe/fake/restore")
        }
    }
}

// MARK: - v3.1.41: container 大工具 + 子命令（合并 3 个 container.* 工具）

final class ContainerExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "container",
        summary: "Manage app data container (refresh/write/delete). Use subcommand to specify action. Use for: read/write/delete files in app container. Don't use for: workspace files (use artifact.*), system files (use shell.exec). Example: write → container write bundle_id:com.xxx path:Documents/xxx.txt text:hello. Subcommands: refresh / write / delete.",
        parameters: [
            "command": "Subcommand: refresh / write / delete",
            "bundle_id": "App bundle ID",
            "path": "File path (for write/delete)",
            "text": "Text to write (for write)"
        ],
        verified: true, category: "fs")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("container", detail: command)
        
        switch command {
        case "refresh":
            return try RefreshContainerTool().invoke([:])
            
        case "write":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required")
            }
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required")
            }
            return try ContainerWriteTextTool().invoke(["bundle_id": bundleId, "path": path, "text": text])
            
        case "delete":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required")
            }
            return try ContainerDeleteTool().invoke(["bundle_id": bundleId, "path": path])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: refresh/write/delete")
        }
    }
}

// MARK: - v3.1.42: diagnose 大工具 + 子命令（合并 2 个 diagnose.* 工具）

final class DiagnoseExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose",
        summary: "Diagnose app/injection issues (startup/injection). Use subcommand to specify action. Use for: diagnose why app won't launch, why injection failed. Don't use for: fix issues (use inject.*), restart app (use app restart). Example: startup → diagnose startup bundle_id:com.xxx; injection → diagnose injection bundle_id:com.xxx. Subcommands: startup / injection.",
        parameters: [
            "command": "Subcommand: startup / injection",
            "bundle_id": "App bundle ID"
        ],
        verified: true, category: "diagnose")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("diagnose", detail: command)
        
        switch command {
        case "startup":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try DiagnoseStartupTool().invoke(["bundle_id": bundleId])
            
        case "injection":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionDiagnoseTool().invoke(["bundle_id": bundleId])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: startup/injection")
        }
    }
}

// MARK: - v3.1.43: memory 大工具 + 子命令（合并 3 个 assistant.memory.* 工具）

final class MemoryExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "memory",
        summary: "Manage assistant memory (set/list/delete). Use subcommand to specify action. Use for: save/list/delete memory notes. Don't use for: game memory modification (use memory game). Example: set → memory set key:user name value:xxx; list → memory list. Subcommands: set / list / delete.",
        parameters: [
            "command": "Subcommand: set / list / delete",
            "key": "Memory key (for set/delete)",
            "value": "Memory value (for set)"
        ],
        verified: true, category: "knowledge")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("memory", detail: command)
        
        switch command {
        case "set":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required")
            }
            guard let value = params["value"] as? String else {
                throw MCPError.invalidParams("value required")
            }
            return try AssistantMemorySetTool().invoke(["key": key, "value": value])
            
        case "list":
            return try AssistantMemoryListTool().invoke([:])
            
        case "delete":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required")
            }
            return try AssistantMemoryDeleteTool().invoke(["key": key])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: set/list/delete")
        }
    }
}

// MARK: - v3.1.44: verify 大工具 + 子命令（合并 2 个 verify.* 工具）

final class VerifyExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "verify",
        summary: "Verify file/app status (file/app_running). Use subcommand to specify action. Use for: verify file exists, check if app is running. Don't use for: read file (use artifact read), launch app (use app launch). Example: file → verify file path:/var/mobile/xxx; app_running → verify app_running bundle_id:com.xxx. Subcommands: file / app_running.",
        parameters: [
            "command": "Subcommand: file / app_running",
            "path": "File path (for file)",
            "bundle_id": "App bundle ID (for app_running)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("verify", detail: command)
        
        switch command {
        case "file":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required")
            }
            return try VerifyFileTool().invoke(["path": path])
            
        case "app_running":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try VerifyAppRunningTool().invoke(["bundle_id": bundleId])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: file/app_running")
        }
    }
}

// MARK: - v3.1.45: ssh 大工具 + 子命令（合并 2 个 ssh.* 工具）

final class SshExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "ssh",
        summary: "SSH remote connection (exec/scp). Use subcommand to specify action. Use for: run commands on remote server, transfer files. Don't use for: local shell (use shell.exec). Example: exec → ssh exec command:ls -la; scp → ssh scp local:xxx remote:/xxx. Subcommands: exec / scp.",
        parameters: [
            "command": "Subcommand: exec / scp",
            "cmd": "Command to run (for exec)",
            "local": "Local file path (for scp)",
            "remote": "Remote file path (for scp)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("ssh", detail: command)
        
        switch command {
        case "exec":
            guard let cmd = params["cmd"] as? String else {
                throw MCPError.invalidParams("cmd required")
            }
            return try SSHTool().invoke(["command": cmd])
            
        case "scp":
            guard let local = params["local"] as? String else {
                throw MCPError.invalidParams("local required")
            }
            guard let remote = params["remote"] as? String else {
                throw MCPError.invalidParams("remote required")
            }
            return try SCPTool().invoke(["local": local, "remote": remote])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: exec/scp")
        }
    }
}

// MARK: - v3.1.48: macro 大工具 + 子命令（合并 6 个 macro.* 工具）

final class MacroExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "macro",
        summary: "Manage operation macros (record/stop/run/list/delete/export). Use subcommand to specify action. Use for: record and replay UI operations. Don't use for: one-off UI control (use control.*). Example: record → macro record name:login; run → macro run name:login. Subcommands: record / stop / run / list / delete / export.",
        parameters: [
            "command": "Subcommand: record / stop / run / list / delete / export",
            "name": "Macro name"
        ],
        verified: true, category: "automation")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("macro", detail: command)
        
        switch command {
        case "record":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try MacroRecordTool().invoke(["name": name])
            
        case "stop":
            return try MacroStopTool().invoke([:])
            
        case "run":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try MacroRunTool().invoke(["name": name])
            
        case "list":
            return try MacroListTool().invoke([:])
            
        case "delete":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try MacroDeleteTool().invoke(["name": name])
            
        case "export":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try MacroExportTool().invoke(["name": name])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: record/stop/run/list/delete/export")
        }
    }
}

// MARK: - v3.1.49: model 大工具 + 子命令（合并 6 个 model.* 工具）

final class ModelExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "model",
        summary: "Manage LLM model (config/update/auth/list/switch). Use subcommand to specify action. Use for: view/switch model config, update auth. Don't use for: chat (use chat.*). Example: list → model list; switch → model switch name:deepseek. Subcommands: config / update / auth / list / switch / selected.",
        parameters: [
            "command": "Subcommand: config / update / auth / list / switch / selected",
            "name": "Model name (for switch)",
            "key": "Auth key (for auth)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("model", detail: command)
        
        switch command {
        case "config":
            return try ModelConfigTool().invoke([:])
            
        case "update":
            return try ModelUpdateTool().invoke([:])
            
        case "auth":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required")
            }
            return try ModelAuthenticationTool().invoke(["key": key])
            
        case "list":
            return try ModelListTool().invoke([:])
            
        case "switch":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try ModelSwitchTool().invoke(["name": name])
            
        case "selected":
            return try ModelSelectedProfileIDTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: config/update/auth/list/switch/selected")
        }
    }
}

// MARK: - v3.1.50: knowledge 大工具 + 子命令（合并 4 个 knowledge.* 工具）

final class KnowledgeExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "knowledge",
        summary: "Manage knowledge base (import_text/import_file/search/delete). Use subcommand to specify action. Use for: save/search/delete knowledge entries. Don't use for: chat memory (use memory.*). Example: search → knowledge search query:xxx; import_text → knowledge import_text text:xxx. Subcommands: import_text / import_file / search / delete.",
        parameters: [
            "command": "Subcommand: import_text / import_file / search / delete",
            "text": "Text to import (for import_text)",
            "path": "File path (for import_file)",
            "query": "Search query (for search)",
            "id": "Knowledge ID (for delete)"
        ],
        verified: true, category: "knowledge")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("knowledge", detail: command)
        
        switch command {
        case "import_text":
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required")
            }
            return try KnowledgeImportTextTool().invoke(["text": text])
            
        case "import_file":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required")
            }
            return try KnowledgeImportFileTool().invoke(["path": path])
            
        case "search":
            guard let query = params["query"] as? String else {
                throw MCPError.invalidParams("query required")
            }
            return try KnowledgeSearchTool().invoke(["query": query])
            
        case "delete":
            guard let id = params["id"] as? String else {
                throw MCPError.invalidParams("id required")
            }
            return try KnowledgeDeleteTool().invoke(["id": id])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: import_text/import_file/search/delete")
        }
    }
}
