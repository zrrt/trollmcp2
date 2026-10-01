import Foundation
import UIKit

// MARK: - 已内联进大工具的历史独立工具（保留类供引用/兼容）：
//   artifact.* → ArtifactExecTool（read/write/list 内联，见 v4.0.0）
//   device.* → DeviceExecTool（委托调用 DeviceInfoTool/DeviceProbeTool 等）

final class DeviceInfoTool: MCPTool {
    let definition = ToolDefinition(name: "device.info", summary: "Get device info: iOS version, iPhone model, memory/storage, battery, TrollAgent version, workspace path. Use for: check what iOS version, know device specs, find workspace path. Don't use for: spoof/change device info (use device.fake), wipe keychain (use device.keychain_wipe). Example: user says 'what model is my phone' → get device info.", verified: true, category: "device")

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
        summary: "Probe/check device environment: TrollStore installed, can we inject, what permissions available. Use for: check if device supports injection, see what capabilities are available. Don't use for: get device specs (use device.info), check battery/memory (use device.snapshot). Example: user says 'can my phone inject, how is the environment' → probe device.",
        verified: true, category: "device")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let r = DeviceProbe.shared.run()
        // v2.9.125：CLI 式一句话结论 (dispatch 取 message 放顶层）
        let failedChecks = r.checks.filter { !$0.passed }
        let message: String
        if r.ready {
            message = "environment ready (TrollStore OK, permissions OK, toolchain OK)"
        } else {
            let labels = failedChecks.prefix(3).map { $0.label }.joined(separator: "、")
            message = "environment not ready: \(labels.isEmpty ? "unknown reason" : labels)"
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

// MARK: - MemoryTweak (H5GG 式内存修改，通过注入的 dylib HTTP API 通信）

final class MemoryTweakTool: MCPTool {
    let definition = ToolDefinition(
        name: "memory",
        summary: "Game memory modification (like GameGuardian/H5GG). Use for: modify game values like coins, HP, lives, scores. Don't use for: read app files (use shell.exec cat), network capture (use network.capture). Prerequisite: inject MemoryTweak.dylib into target game first. Workflow: 1) search for current value, 2) change value in game, 3) refine search, 4) write new value. Example: user says 'modify coins' → search coin count in game memory.",
        parameters: [
            "action": "attach (确认已注入并连接，injected dylib 后服务即已 attach，等价 status) / search (first scan) / refine (filter results) / write (set new value) / freeze (lock value) / unfreeze / status / frozen (list locked values)",
            "value": "Value to search/write/freeze. e.g. 1000 coins, 50 HP",
            "type": "Data type: int (integer, default) / int64 / float (decimal) / double / byte / short",
            "address": "Memory address (0x hex format, required for write/freeze)"
        ],
        prerequisites: ["目标游戏已injected MemoryTweak.dylib (先 inject enable MemoryTweak 到目标 App)", "attach/status 确认连接OK (HTTP 127.0.0.1:8765 可达)后才 search/refine/write/freeze"]
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
        // v3.1.69: attach —— 指引里反复提 "memory attach"，但此前无此动作 (AI 反馈属实）。
        // MemoryTweak.dylib 被注入目标进程后 HTTP 服务即已 attach (无独立 attach 端点），
        // attach 动作等价确认服务在线/进程已注入，转发 /status。
        case "attach":
            method = "GET"; path = "/status"
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
            return ["error": "failed to connect MemoryTweak (\(error.localizedDescription). Confirm MemoryTweak.dylib injected into target App and target App is running.", "connected": false]
        }
        guard let data = resultData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "failed to parse response", "connected": false]
        }
        return json
    }
}



// MARK: - v3.1.39: artifact 大工具 + 子命令 (合并 3 个 artifact.* 工具）

final class ArtifactExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact",
        summary: "Manage workspace files (read/write/list/output_name/output_bookmark). Use subcommand to specify action. Use for: read/write/list files in workspace, set output name. Don't use for: read app container files (use shell.exec cat), system files (use shell.exec). Example: read → artifact read filename:report.txt; list → artifact list. Subcommands: read / write / list / output_name_get / output_name_set / output_bookmark. REQUIRED PARAMS per subcommand: read→filename; write→filename+text; output_name_set→name; others→none.",
        parameters: [
            "command": "Subcommand (required): read / write / list / output_name_get / output_name_set / output_bookmark",
            "filename": "File name — REQUIRED for read/write",
            "text": "Text to write — REQUIRED for write",
            "name": "Output name — REQUIRED for output_name_set"
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
                throw MCPError.invalidParams("filename required. Usage: artifact read filename:report.txt")
            }
            // v4.0.0: 内联自 ArtifactReadTextTool（修复原委托调用传参 key 不一致的隐藏 bug）
            let url = try Workspace.resolve(filename)
            let text = try String(contentsOf: url, encoding: .utf8)
            return ["content": text]
            
        case "write":
            guard let filename = params["filename"] as? String else {
                throw MCPError.invalidParams("filename required. Usage: artifact write filename:notes.txt text:<content>")
            }
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: artifact write filename:notes.txt text:<content>")
            }
            // v4.0.0: 内联自 ArtifactWriteTextTool（修复委托传参 key 不一致的隐藏 bug）
            let url = try Workspace.resolve(filename)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ["written": true, "bytes": text.utf8.count]
            
        case "list":
            // v4.0.0: 内联自 ArtifactListTool（subpath 可选；文件返回单条，目录返回前 50 条）
            let sub = params["subpath"] as? String ?? ""
            let dir = try Workspace.resolve(sub)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
                return ["entries": [], "error": "path does not exist: \(sub)"]
            }
            if !isDir.boolValue {
                let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return ["entries": [
                    ["name": dir.lastPathComponent,
                     "path": dir.path,
                     "isDirectory": false,
                     "size": size,
                     "hint": "this is a file not a directory; to read it use artifact read (text) or shell.exec for the raw file"]
                ]]
            }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let entries = items.map { name -> [String: Any] in
                var isD: ObjCBool = false
                let p = (dir.path as NSString).appendingPathComponent(name)
                _ = FileManager.default.fileExists(atPath: p, isDirectory: &isD)
                return ["name": name, "path": p, "isDirectory": isD.boolValue]
            }
            let limited = Array(entries.prefix(50))
            return ["entries": limited, "total": entries.count, "truncated": entries.count > 50, "hint": entries.count > 50 ? "directory has \(entries.count) items, only first 50 returned; use shell.exec find for precise search" : ""]

        case "output_name_get":
            // v4.0.0: 内联自 WorkspaceOutputNameTool
            return ["name": UserDefaults.standard.string(forKey: "trollmcp2.output_name") ?? "artifact"]

        case "output_name_set":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required. Usage: artifact output_name_set name:<output name>")
            }
            // v4.0.0: 内联自 WorkspaceOutputNameTool
            UserDefaults.standard.set(name, forKey: "trollmcp2.output_name")
            return ["set": name]

        case "output_bookmark":
            // v4.0.0: 内联自 WorkspaceOutputBookmarkTool（返回当前输出书签路径，默认工作区根）
            let key = "trollmcp2.output_bookmark"
            return ["bookmark": UserDefaults.standard.string(forKey: key) ?? "/var/mobile/Documents/Workspace"]

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: read/write/list/output_name_get/output_name_set/output_bookmark")
        }
    }
}

// MARK: - v3.1.40: device 大工具 + 子命令 (合并 4 个 device.* 工具）

final class DeviceExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "device",
        summary: "Manage device info and spoofing (info/probe/fake/restore/advertising/idfv/snapshot). Use subcommand to specify action. Use for: get device info, spoof device identity, get advertising ID / IDFV, device snapshot. Don't use for: app management (use app.*), injection (use inject.*). Example: info → device info; fake → device fake; snapshot → device snapshot. Subcommands: info / probe / fake / restore / advertising / idfv / snapshot.",
        parameters: [
            "command": "Subcommand: info / probe / fake / restore / advertising / idfv / snapshot"
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

        case "advertising":
            return try AdvertisingTool().invoke([:])

        case "idfv":
            return try IdfvTool().invoke([:])

        case "snapshot":
            return try DeviceSnapshotTool().invoke([:])

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: info/probe/fake/restore/advertising/idfv/snapshot")
        }
    }
}

// MARK: - v3.1.41: container 大工具 + 子命令 (合并 3 个 container.* 工具）

final class ContainerExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "container",
        summary: "Manage app data container (refresh/resolve/write/delete). Use subcommand to specify action. Use for: read/write/delete files in app container, resolve app install+data paths. Don't use for: workspace files (use artifact.*), system files (use shell.exec). Example: write → container write bundle_id:com.xxx path:Documents/xxx.txt text:hello; resolve → container resolve bundle_id:com.xxx. Subcommands: refresh / resolve / write / delete. REQUIRED PARAMS per subcommand: write→bundle_id+path+text; delete→bundle_id+path; resolve→bundle_id; refresh→none.",
        parameters: [
            "command": "Subcommand (required): refresh / resolve / write / delete",
            "bundle_id": "App bundle ID — REQUIRED for resolve/write/delete",
            "path": "File path — REQUIRED for write/delete",
            "text": "Text to write — REQUIRED for write"
        ],
        verified: true, category: "fs", prerequisites: ["resolve/write/delete 的 bundle_id 必须对应已安装 App (先 app status 确认)", "refresh has no prerequisite, callable anytime"])
    
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
                throw MCPError.invalidParams("bundle_id required. Usage: container write bundle_id:com.xxx path:Documents/a.txt text:<content>")
            }
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required. Usage: container write bundle_id:com.xxx path:Documents/a.txt text:<content>")
            }
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: container write bundle_id:com.xxx path:Documents/a.txt text:<content>")
            }
            return try ContainerWriteTextTool().invoke(["bundle_id": bundleId, "path": path, "text": text])
            
        case "delete":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required. Usage: container delete bundle_id:com.xxx path:Documents/a.txt")
            }
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required. Usage: container delete bundle_id:com.xxx path:Documents/a.txt")
            }
            return try ContainerDeleteTool().invoke(["bundle_id": bundleId, "path": path])
            
        // v3.1.68: container resolve —— bundle_id → 安装目录 + 数据容器 + 沙盒路径
        // 此前 AI 为了找某 App 的数据目录要 loop 几百个目录跑 plutil (又慢又易崩），
        // 一条 resolve 直接给出全部路径 (D items修复，2026-09-23 实测确认缺失）
        case "resolve":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required. Usage: container resolve bundle_id:com.xxx")
            }
            return try ContainerResolveTool().invoke(["bundle_id": bundleId])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: refresh/resolve/write/delete")
        }
    }
}

// MARK: - v3.1.42: diagnose 大工具 + 子命令 (合并 2 个 diagnose.* 工具）

final class DiagnoseExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose",
        summary: "Diagnose app/injection issues (startup/injection). Use subcommand to specify action. Use for: diagnose why app won't launch, why injection failed. Don't use for: fix issues (use inject.*), restart app (use app restart). Example: startup → diagnose startup bundle_id:com.xxx; injection → diagnose injection bundle_id:com.xxx. Subcommands: startup / injection.",
        parameters: [
            "command": "Subcommand: startup / injection",
            "bundle_id": "App bundle ID"
        ],
        verified: true, category: "diagnose", prerequisites: ["App 已安装且 bundle_id 有效 (先 app status 确认)", "startup 诊断依赖 App 曾启动过 (有崩溃日志才有意义)"])
    
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

// MARK: - v3.1.43: memory 大工具 + 子命令 (合并 3 个 assistant.memory.* 工具）

final class MemoryExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "assistant_memory",
        summary: "Manage assistant memory (set/list/delete). Use subcommand to specify action. Use for: save/list/delete memory notes. Don't use for: game memory modification (use memory action:search). Example: set → assistant_memory set key:user name value:xxx; list → assistant_memory list. Subcommands: set / list / delete.",
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
        
        AuditLog.shared.log("assistant_memory", detail: command)
        
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

// MARK: - v3.1.44: verify 大工具 + 子命令 (合并 2 个 verify.* 工具）

final class VerifyExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "verify",
        summary: "Verify file/app status (file/app_running). Use subcommand to specify action. Use for: verify file exists, check if app is running. Don't use for: read file (use artifact read), launch app (use app launch). Example: file → verify file path:/var/mobile/xxx; app_running → verify app_running bundle_id:com.xxx. Subcommands: file / app_running.",
        parameters: [
            "command": "Subcommand: file / app_running",
            "path": "File path (for file)",
            "bundle_id": "App bundle ID (for app_running)"
        ],
        verified: true, category: "system", prerequisites: ["app_running 前确认 bundle_id 已安装且曾启动过 (app.launch 后验证才有意义)", "path must be a real absolute path before file verification"])
    
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

// MARK: - v3.1.45: ssh 大工具 + 子命令 (合并 2 个 ssh.* 工具）

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

// MARK: - v3.1.48: macro 大工具 + 子命令 (合并 6 个 macro.* 工具）

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

// MARK: - v3.1.49: model 大工具 + 子命令 (合并 6 个 model.* 工具）

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

// MARK: - v3.1.50: knowledge 大工具 + 子命令 (合并 4 个 knowledge.* 工具）

final class KnowledgeExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "knowledge",
        summary: "Manage knowledge base (import_text/import_file/search/delete/clear). Use subcommand to specify action. Use for: save/search/delete knowledge entries, or clear the whole base. Don't use for: chat memory (use memory set/list). Example: search → knowledge search query:xxx; clear → knowledge clear. Subcommands: import_text / import_file / search / delete / clear.",
        parameters: [
            "command": "Subcommand: import_text / import_file / search / delete / clear",
            "text": "Text to import (for import_text)",
            "name": "Entry name (optional for import_text, required for delete)",
            "path": "File path (for import_file)",
            "query": "Search query (for search)",
            "id": "Knowledge entry name (alias for name, for delete)"
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
            // v4.3.66：子工具要求 name+content（此前只传 text 必崩）；name 缺省自动生成
            let name = params["name"] as? String ?? "笔记-\(Int(Date().timeIntervalSince1970))"
            return try KnowledgeImportTextTool().invoke(["name": name, "content": text])
            
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
            // v4.3.66：子工具要求 name（此前传 id 必崩）；兼容 name/id 两种入参
            guard let name = params["name"] as? String ?? params["id"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try KnowledgeDeleteTool().invoke(["name": name])

        case "clear":
            let removed = KnowledgeStore.shared.clearAll()
            return ["cleared": true, "removed": removed, "note": "已清空知识库（含 session_memory.md，将自动重建）"]

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: import_text/import_file/search/delete/clear")
        }
    }
}

// MARK: - v3.1.51: location 大工具 + 子命令 (合并 4 个 location.* 工具）

final class LocationExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "location",
        summary: "Manage location (get/fake/status/clear). Use subcommand to specify action. Use for: get current location, fake location. Don't use for: device info (use device info). Example: get → location get; fake → location fake lat:39.9 lng:116.4. Subcommands: get / fake / status / clear.",
        parameters: [
            "command": "Subcommand: get / fake / status / clear",
            "lat": "Latitude (for fake)",
            "lng": "Longitude (for fake)"
        ],
        verified: true, category: "device")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("location", detail: command)
        
        switch command {
        case "get":
            return try LocationGetTool().invoke([:])
            
        case "fake":
            guard let lat = params["lat"] as? Double else {
                throw MCPError.invalidParams("lat required")
            }
            guard let lng = params["lng"] as? Double else {
                throw MCPError.invalidParams("lng required")
            }
            return try LocationFakeTool().invoke(["lat": lat, "lng": lng])
            
        case "status":
            return try LocationFakeStatusTool().invoke([:])
            
        case "clear":
            return try LocationFakeClearTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: get/fake/status/clear")
        }
    }
}

// MARK: - v3.1.52: github 大工具 + 子命令 (合并 4 个 github.* 工具）

final class GitHubExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "github",
        summary: "Manage GitHub CI (account_status/trigger_build/fetch_runs/download_artifact). Use subcommand to specify action. Use for: trigger build, check status, download artifact. Don't use for: code search (use web.search). Example: trigger_build → github trigger_build; fetch_runs → github fetch_runs. Subcommands: account_status / trigger_build / fetch_runs / download_artifact.",
        parameters: [
            "command": "Subcommand: account_status / trigger_build / fetch_runs / download_artifact",
            "workflow": "Workflow file for trigger_build: build-trollmcp2.yml (default, build IPA) or build-tweak.yml (build tweak dylib)",
            "tweak": "Only for tweak trigger_build: tweak project name (e.g. ProbeAgent / ConfigHook / NetworkTweak)",
            "ref": "Git branch to build (default main)",
            "run_id": "Run ID (for download_artifact)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("github", detail: command)
        
        switch command {
        case "account_status":
            return try GitHubAccountStatusTool().invoke([:])
            
        case "trigger_build":
            return try GitHubTriggerBuildTool().invoke(params)
            
        case "fetch_runs":
            return try GitHubFetchRunsTool().invoke(params)
            
        case "download_artifact":
            guard let runId = params["run_id"] as? Int else {
                throw MCPError.invalidParams("run_id required")
            }
            return try GitHubDownloadArtifactTool().invoke(["run_id": runId])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: account_status/trigger_build/fetch_runs/download_artifact")
        }
    }
}
