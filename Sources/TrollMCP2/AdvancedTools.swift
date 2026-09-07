import Foundation
import UIKit

// MARK: - v2.9.90 高级工具组（借鉴 Fuck 巨魔工具箱：opainject 内存注入 / ProbeEngine 类探测 / FuckEngine 配置化 Hook / 绿盾式设备伪装）
//
// 新能力：
//  - injection.mem   内存注入（opainject：task_for_pid + ROP → dlopen，不改文件、零残留、App 重启即消失）
//  - probe.inspect   运行时类探测（ProbeAgent：枚举 ObjC 类/方法/属性/UserDefaults）
//  - hook.apply      配置化 Hook（ConfigHook：hook_config.json 驱动 UIKit 修改，重启即生效）
//  - device.fake     设备伪装（FakeDevice：fake_device.json 驱动 UIDevice 伪装）
//  - device.restore  还原设备伪装

// MARK: - 进程/启动辅助

enum ProcessHelper {
    /// 按可执行名查 pid（ps -A 解析；App 主进程名 = CFBundleExecutable）
    static func pidOf(executableName: String) -> Int? {
        let (_, out) = InjectionManager.shared.spawn("/bin/ps", args: ["ps", "-A", "-o", "pid=,comm="])
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let pidStr = String(trimmed[..<spaceIdx]).trimmingCharacters(in: .whitespaces)
            let comm = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            if comm == executableName, let pid = Int(pidStr) {
                return pid
            }
        }
        return nil
    }

    /// 启动 App：优先 SBSLaunchApplicationWithIdentifier（需 frontboard/springboard entitlements），失败回退 openURL，再失败返回提示
    @discardableResult
    static func launchApp(bundleId: String) -> (Bool, String) {
        // 1) 尝试 SpringBoardServices private API
        if let handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY) {
            typealias SBSLaunchFn = @convention(c) (CFString, Bool) -> Int32
            if let sym = dlsym(handle, "SBSLaunchApplicationWithIdentifier") {
                let fn = unsafeBitCast(sym, to: SBSLaunchFn.self)
                let ret = fn(bundleId as CFString, false)
                if ret == 0 {
                    return (true, "SBSLaunchApplicationWithIdentifier 启动成功")
                }
            }
            dlclose(handle)
        }
        // 2) 回退：openURL（需要 App 有 URL scheme）
        if let url = URL(string: "trollmcp2://") {
            var opened = false
            let sem = DispatchSemaphore(value: 0)
            UIApplication.shared.open(url, options: [:]) { success in
                opened = success
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 3)
            if opened { return (true, "openURL 启动成功") }
        }
        return (false, "无法自动启动（SBS 不可用且 App 无 URL scheme），请在桌面手动打开目标 App")
    }

    /// 找 App 主可执行名（CFBundleExecutable）
    static func executableName(for app: AppCatalog.AppEntry) -> String {
        guard let dict = NSDictionary(contentsOfFile: app.path + "/Info.plist"),
              let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty else {
            return app.bundleId.components(separatedBy: ".").last ?? app.bundleId
        }
        return exe
    }

    /// tweaks 目录内 dylib 路径
    static func tweakPath(_ name: String) -> String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("tweaks").appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 写 JSON 配置文件到工作区
    static func writeWorkspaceConfig(_ fileName: String, dict: [String: Any]) -> Bool {
        let dir = "/var/mobile/Documents/Workspace"
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let path = dir + "/" + fileName
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    static func removeWorkspaceConfig(_ fileName: String) -> Bool {
        let path = "/var/mobile/Documents/Workspace/" + fileName
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - injection.mem：内存注入（opainject）

final class InjectionMemTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.mem",
        summary: "内存注入：用 opainject 向运行中的目标 App 进程注入 dylib（task_for_pid + ROP → dlopen）。不改二进制、无备份、零残留，App 重启后注入自动消失。适合临时测试/探测。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "dylib_path": "要注入的 dylib 绝对路径（可选，不填则用内置 tweaks/ProbeAgent.dylib）",
            "auto_launch": "App 未运行时是否尝试自动启动（true/false，默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)", "hint": "用 injection.list 搜索"]
        }
        let exeName = ProcessHelper.executableName(for: app)
        var dylibPath = params["dylib_path"] as? String ?? ""
        if dylibPath.isEmpty {
            dylibPath = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
        }
        guard !dylibPath.isEmpty, FileManager.default.fileExists(atPath: dylibPath) else {
            return ["error": "dylib 不存在: \(dylibPath)", "hint": "传 dylib_path 或确保内置 tweaks/ProbeAgent.dylib 存在"]
        }

        // 1. 查进程；未运行则尝试启动
        var pid = ProcessHelper.pidOf(executableName: exeName)
        if pid == nil {
            let autoLaunch = (params["auto_launch"] as? Bool) ?? true
            if autoLaunch {
                _ = ProcessHelper.launchApp(bundleId: bundleId)
                for _ in 0..<10 {
                    usleep(500_000)
                    pid = ProcessHelper.pidOf(executableName: exeName)
                    if pid != nil { break }
                }
            }
        }
        guard let targetPid = pid else {
            return ["error": "目标 App 未运行，无法内存注入", "hint": "先打开目标 App，或传 auto_launch=true"]
        }

        // 2. 执行 opainject <pid> <dylib>
        AuditLog.shared.log("injection.mem", detail: "\(bundleId) pid=\(targetPid)")
        let (exit, output) = InjectionManager.shared.runAsRoot("opainject", args: ["\(targetPid)", dylibPath])
        let success = output.contains("dlopen succeeded") || (exit == 0 && output.contains("handle"))
        return [
            "status": success ? "injected" : "failed",
            "mode": "memory",
            "bundle_id": bundleId,
            "app": app.name,
            "pid": targetPid,
            "dylib": dylibPath,
            "exit": exit,
            "output": output,
            "note": success ? "内存注入成功：进程内已 dlopen，不改文件；App 重启后注入自动消失" : "opainject 失败，见 output 定位原因（权限/架构/进程状态）"
        ]
    }
}

// MARK: - probe.inspect：运行时类探测（ProbeAgent）

final class ProbeInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "probe.inspect",
        summary: "运行时探测目标 App：枚举 ObjC 类/类详情（方法·属性·ivars）/UserDefaults/进程信息。用 ProbeAgent 内存注入 + localhost:4791 查询，探测完可自动清理。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "query": "查询类型：classes（类列表）/ class（类详情）/ userdefaults / info，默认 classes",
            "class_name": "query=class 时要查的类名（如 UIApplicationDelegate 实现类）",
            "prefix": "类名前缀过滤（可选，如 QQ 前缀避免全量）",
            "limit": "类列表条数上限（默认 30，最大 100）",
            "cleanup": "探测完是否移除注入（true/false，默认 false——进程活着期间可反复查询）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)", "hint": "用 injection.list 搜索"]
        }
        let query = (params["query"] as? String) ?? "classes"
        let exeName = ProcessHelper.executableName(for: app)

        // 1. 确保 ProbeAgent 已注入（内存注入；若 App 在运行且已注入则跳过）
        var probeInjected = false
        if let pid = ProcessHelper.pidOf(executableName: exeName) {
            // 简单探测：请求 /status 看 ProbeAgent 是否已在
            if let (code, body) = httpGet(port: 4791, path: "/status"), code == 200 {
                probeInjected = true
            } else {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.runAsRoot("opainject", args: ["\(pid)", dylib])
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        } else {
            // App 未运行：先启动再注入
            let (launched, msg) = ProcessHelper.launchApp(bundleId: bundleId)
            if !launched { return ["error": msg, "hint": "手动打开目标 App 后重试"] }
            var pid: Int? = nil
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
            if let pid = pid {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.runAsRoot("opainject", args: ["\(pid)", dylib])
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        }
        guard probeInjected else {
            return ["error": "ProbeAgent 注入失败（App 未运行或 opainject 失败）", "hint": "确认 App 在前台运行，或先手动打开"]
        }

        // 2. 等待 ProbeAgent HTTP 就绪（constructor 延迟 1s）
        var ready = false
        for _ in 0..<10 {
            usleep(400_000)
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 { ready = true; break }
        }
        guard ready else {
            return ["error": "ProbeAgent HTTP 未就绪（端口 4791）"]
        }

        // 3. 执行查询
        var path = "/probe/classes"
        var limit = params["limit"] as? Int ?? 30
        if limit > 100 { limit = 100 }
        let prefix = params["prefix"] as? String ?? ""
        switch query {
        case "class":
            guard let cn = params["class_name"] as? String, !cn.isEmpty else {
                throw MCPError.invalidParams("query=class 需要 class_name 参数")
            }
            path = "/probe/class?name=" + cn.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        case "userdefaults":
            path = "/probe/userdefaults"
        case "info":
            path = "/status"
        default:
            var qs = "limit=\(limit)"
            if !prefix.isEmpty { qs += "&prefix=" + prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }
            path = "/probe/classes?" + qs
        }
        guard let (code, body) = httpGet(port: 4791, path: path) else {
            return ["error": "ProbeAgent 查询超时"]
        }
        var result: [String: Any] = ["status": code == 200 ? "ok" : "error", "query": query, "bundle_id": bundleId, "app": app.name]
        if let data = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result["data"] = obj
        } else {
            result["raw"] = body
        }

        // 4. 清理
        let cleanup = (params["cleanup"] as? Bool) ?? false
        if cleanup {
            if let pid = ProcessHelper.pidOf(executableName: exeName) {
                _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exeName])
                result["cleanup"] = "已 kill 目标进程，内存注入随进程退出消失"
            }
        } else {
            result["cleanup"] = "保留注入（进程存活期间可反复查询）；用 cleanup=true 或重启 App 清除"
        }
        AuditLog.shared.log("probe.inspect", detail: "\(bundleId) query=\(query)")
        return result
    }
}

// MARK: - hook.apply：配置化 Hook（ConfigHook）

final class HookApplyTool: MCPTool {
    let definition = ToolDefinition(
        name: "hook.apply",
        summary: "配置化 Hook：向目标 App 注入 ConfigHook，并写入 hook_config.json（导航栏颜色/全局 tint/启动弹窗/方法调用日志）。改配置后重启 App 即生效，无需重新注入。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "config": "配置 JSON 字符串：{\"navBarColor\":\"#1A73E8\",\"navBarTitleColor\":\"#FFFFFF\",\"windowTint\":\"#FF0000\",\"alert\":{\"title\":\"..\",\"message\":\"..\"},\"methodLog\":[{\"class\":\"X\",\"selector\":\"y\"}]}",
            "restart": "注入后是否重启 App（true/false，默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)"]
        }
        // 1. 解析配置
        var config: [String: Any] = [:]
        if let cfg = params["config"] as? String, !cfg.isEmpty {
            guard let data = cfg.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPError.invalidParams("config 不是合法 JSON")
            }
            config = obj
        } else if let dict = params["config"] as? [String: Any] {
            config = dict
        }
        guard !config.isEmpty else {
            throw MCPError.invalidParams("config 不能为空")
        }
        // 2. 写配置文件
        guard ProcessHelper.writeWorkspaceConfig("hook_config.json", dict: config) else {
            return ["error": "写入 hook_config.json 失败（工作区权限）"]
        }
        // 3. 检查/执行注入（文件注入持久化：App 重启后 ConfigHook 仍在，读最新配置生效）
        let injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
        if !injected {
            let dylib = ProcessHelper.tweakPath("ConfigHook.dylib") ?? ""
            guard !dylib.isEmpty else { return ["error": "内置 ConfigHook.dylib 不存在"] }
            let r = try InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
            if (r["status"] as? String) != "injected" {
                return ["error": "ConfigHook 注入失败", "detail": r]
            }
        }
        // 4. 重启生效
        let restart = (params["restart"] as? Bool) ?? true
        var relaunchNote = ""
        if restart {
            let exe = ProcessHelper.executableName(for: app)
            _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
            _ = ProcessHelper.launchApp(bundleId: bundleId)
            relaunchNote = "已重启 App 使配置生效"
        } else {
            relaunchNote = "未重启；下次 App 启动时配置生效"
        }
        AuditLog.shared.log("hook.apply", detail: "\(bundleId) keys=\(config.keys)")
        return [
            "status": "applied",
            "bundle_id": bundleId,
            "app": app.name,
            "config_path": "/var/mobile/Documents/Workspace/hook_config.json",
            "config": config,
            "injected": true,
            "note": relaunchNote + "；修改配置后重启 App 即生效（无需重新注入）"
        ]
    }
}

// MARK: - device.fake / device.restore：设备伪装（FakeDevice，绿盾式）

final class DeviceFakeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.fake",
        summary: "设备伪装：向目标 App 注入 FakeDevice 并写入 fake_device.json，伪装 UIDevice 返回的机型名称/型号/系统版本（绿盾式）。注入后重启 App 生效。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "name": "伪装设备名（如 iPhone 16 Pro Max）",
            "model": "伪装型号（如 iPhone）",
            "model_identifier": "伪装型号标识（如 iPhone17,2，部分 App 通过 sysctl 读取，此项仅记录说明）",
            "system_version": "伪装系统版本（如 18.0）",
            "restart": "注入后是否重启 App（默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)"]
        }
        var config: [String: Any] = [:]
        if let name = params["name"] as? String, !name.isEmpty { config["name"] = name }
        if let model = params["model"] as? String, !model.isEmpty { config["model"] = model }
        if let mi = params["model_identifier"] as? String, !mi.isEmpty { config["modelIdentifier"] = mi }
        if let sv = params["system_version"] as? String, !sv.isEmpty { config["systemVersion"] = sv }
        guard !config.isEmpty else {
            throw MCPError.invalidParams("至少提供一个伪装字段（name/model/model_identifier/system_version）")
        }
        guard ProcessHelper.writeWorkspaceConfig("fake_device.json", dict: config) else {
            return ["error": "写入 fake_device.json 失败（工作区权限）"]
        }
        let injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
        if !injected {
            let dylib = ProcessHelper.tweakPath("FakeDevice.dylib") ?? ""
            guard !dylib.isEmpty else { return ["error": "内置 FakeDevice.dylib 不存在"] }
            let r = try InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
            if (r["status"] as? String) != "injected" {
                return ["error": "FakeDevice 注入失败", "detail": r]
            }
        }
        let restart = (params["restart"] as? Bool) ?? true
        var relaunchNote = ""
        if restart {
            let exe = ProcessHelper.executableName(for: app)
            _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
            _ = ProcessHelper.launchApp(bundleId: bundleId)
            relaunchNote = "已重启 App 使伪装生效"
        } else {
            relaunchNote = "未重启；下次 App 启动时伪装生效"
        }
        AuditLog.shared.log("device.fake", detail: "\(bundleId) \(config)")
        return [
            "status": "faked",
            "bundle_id": bundleId,
            "app": app.name,
            "config": config,
            "config_path": "/var/mobile/Documents/Workspace/fake_device.json",
            "note": relaunchNote + "；device.restore 可还原"
        ]
    }
}

final class DeviceRestoreTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.restore",
        summary: "还原设备伪装：删除 fake_device.json 并移除 FakeDevice 注入，恢复目标 App 真实设备信息。",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        var removed = ProcessHelper.removeWorkspaceConfig("fake_device.json")
        var injected = false
        if let app = AppCatalog.find(bundleId) {
            injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
            if injected {
                _ = try? InjectionManager.shared.disable(bundleId: bundleId)
            }
            let exe = ProcessHelper.executableName(for: app)
            _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
            _ = ProcessHelper.launchApp(bundleId: bundleId)
        } else {
            removed = false
        }
        AuditLog.shared.log("device.restore", detail: bundleId)
        return [
            "status": "restored",
            "bundle_id": bundleId,
            "config_removed": removed,
            "injection_removed": injected,
            "note": "已删除 fake_device.json 并重启 App（若之前注入了 FakeDevice 也已移除）"
        ]
    }
}

// MARK: - HTTP 辅助（localhost）

private func httpGet(port: Int, path: String, timeout: TimeInterval = 4) -> (Int, String)? {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.timeoutInterval = timeout
    var result: (Int, String)? = nil
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let data = data, let http = response as? HTTPURLResponse {
            result = (http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return result
}
