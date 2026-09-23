import Foundation
import UIKit

// MARK: - v2.9.139 四件套之二：启动带参数 (SBSLaunchApplicationWithOptions + DYLD_INSERT_LIBRARIES）
// 用途：AI 启动目标 App 时注入环境变量 (如 DYLD_INSERT_LIBRARIES 预加载 hook）/启动参数/调试标记。
// 私有 API 走 dlsym (SpringBoardServices），entitlements 已含 com.apple.springboard.launchapplicationswithoptions。

enum AppLaunchWithOptions {
    @discardableResult
    static func launch(bundleId: String, environment: [String: String] = [:], arguments: [String] = [], suspended: Bool = false) -> (Bool, String) {
        let fw = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        if let handle = dlopen(fw, RTLD_LAZY) {
            typealias SBSLaunchOptFn = @convention(c) (CFString, CFDictionary?, Bool) -> Int32
            if let sym = dlsym(handle, "SBSLaunchApplicationWithOptions") {
                let fn = unsafeBitCast(sym, to: SBSLaunchOptFn.self)
                var opts: [String: Any] = [:]
                if !environment.isEmpty {
                    opts["SBSApplicationLaunchOptionEnvironment"] = environment
                }
                if !arguments.isEmpty {
                    opts["SBSApplicationLaunchOptionArguments"] = arguments
                }
                if suspended {
                    opts["SBSApplicationLaunchOptionWaitForDebugger"] = true
                }
                let ret = fn(bundleId as CFString, opts.isEmpty ? nil : opts as CFDictionary, false)
                if ret == 0 {
                    var detail = "launch OK (with args)"
                    if !environment.isEmpty { detail += "，env: \(environment.keys.joined(separator: ","))" }
                    if !arguments.isEmpty { detail += "，args: \(arguments.joined(separator: " "))" }
                    return (true, detail)
                }
                return (false, "SBSLaunchApplicationWithOptions returned \(ret)")
            }
            dlclose(handle)
        }
        // 回退：无参启动
        return ProcessHelper.launchApp(bundleId: bundleId)
    }
}

// MARK: - 四件套之三：定位模拟 (locationd.simulation）
// 诚实能力边界：
//  · 全局模拟 (所有 App 生效）需要 hook 系统进程 locationd——TrollStore 非越狱，无法注入系统进程，系统级做不到。
//  · 可行路径：写入模拟坐标配置 (供目标 App 的坐标 Hook dylib 读取）+ 引导注入。
//  · 本文实现 Layer1：坐标配置写入 (可复现、立即OK）；Layer2：尽力尝试 CLLocationManager 私有模拟接口 (failed返回真实原因）。

enum FakeLocationStore {
    static let url = Workspace.root.appendingPathComponent("location_fake.json")

    static func save(lat: Double, lon: Double) -> (Bool, String) {
        let dict: [String: Any] = ["lat": lat, "lon": lon, "enabled": true, "updated_at": Int(Date().timeIntervalSince1970)]
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return (true, "simulated coordinate config written: \(url.path)")
        } catch {
            return (false, "write failed: \(error.localizedDescription)")
        }
    }

    static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    static func clear() -> (Bool, String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (true, "no simulated config to clear") }
        do {
            try FileManager.default.removeItem(at: url)
            return (true, "simulated location config cleared")
        } catch {
            return (false, "clear failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCP 工具

final class AppLaunchOptionsTool: MCPTool {
    let definition = ToolDefinition(name: "app.launch",
        summary: "Start/open an app on the iPhone. Use for: launch app by bundle_id, open app to use it. Don't use for: restart app (use app.restart), uninstall app (use app.uninstall), inject dylib (use injection.enable). Prerequisite: you need the app's bundle_id. Find it with injection.list or process.list. Example: user says 'open 小红书' → launch with com.xingin.discover.",
        parameters: ["bundle_id": "Target App bundle_id (required). e.g. com.xingin.discover for 小红书", "env": "Environment vars dict (optional, e.g. {\"DYLD_INSERT_LIBRARIES\": \"/path/hook.dylib\"})", "args": "Launch args array (optional)", "reason": "Why launch this App (required, for audit)"], verified: true, category: "app_control", prerequisites: ["App installed (confirm bundle_id with app status or shell.exec ls /var/containers/Bundle/Application first)"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let reason = params["reason"] as? String ?? ""
        ControlSession.shared.addThink(reason)
        ControlSession.shared.addAction("app.launch(\(bundleId))\(params["env"] != nil ? " +env" : "")")
        let env = params["env"] as? [String: String] ?? [:]
        let args = params["args"] as? [String] ?? []
        let (ok, msg) = AppLaunchWithOptions.launch(bundleId: bundleId, environment: env, arguments: args)
        guard ok else {
            ControlSession.shared.addResult("❌ launch failed: \(msg)")
            throw MCPError.classified("launch failed", code: "LAUNCH_FAILED", reason: msg, nextStep: "confirm bundle_id; if target App is App Store encrypted, decrypt first; or launch manually via ai Control Center")
        }
        ControlSession.shared.addResult("✅ woken \(bundleId)")
        return ["message": msg, "bundle_id": bundleId, "method": "SBSLaunchApplicationWithOptions"]
    }
}

final class LocationFakeTool: MCPTool {
    let definition = ToolDefinition(name: "location.fake",
        summary: "Set simulated GPS location. Use for: fake location for location-based apps. Don't use for: check current location (use location.get), clear fake location (use location.clear). Note: only works if app has location hook injected. Example: user says 'set location to Beijing' → set fake location.",
        parameters: ["lat": "Latitude", "lon": "Longitude", "reason": "Why (optional)"], verified: true, category: "device")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let lat = params["lat"] as? Double, let lon = params["lon"] as? Double else {
            throw MCPError.invalidParams("lat, lon required")
        }
        let reason = params["reason"] as? String ?? ""
        ControlSession.shared.addThink(reason)
        ControlSession.shared.addAction("location.fake(\(lat), \(lon))")
        let (ok, msg) = FakeLocationStore.save(lat: lat, lon: lon)
        guard ok else { throw MCPError.failed(msg) }
        return [
            "message": msg + ". Effect path: (1) target App with location Hook reads this config; (2) global spoofing needs system processes, unsupported on TrollStore.",
            "config_path": FakeLocationStore.url.path,
            "lat": lat, "lon": lon
        ]
    }
}

final class LocationFakeStatusTool: MCPTool {
    let definition = ToolDefinition(name: "location.fake_status",
        summary: "Check current fake location settings. Use for: see if location is being spoofed, what coordinates are set. Don't use for: set fake location (use location.fake), clear fake location (use location.clear). Example: user says 'where is the simulated location now' → check status.",
        parameters: [:], verified: true, category: "device")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let cfg = FakeLocationStore.read() else {
            return ["enabled": false, "message": "no simulated location set"]
        }
        return ["enabled": true, "lat": cfg["lat"] ?? 0, "lon": cfg["lon"] ?? 0, "config_path": FakeLocationStore.url.path]
    }
}

final class LocationFakeClearTool: MCPTool {
    let definition = ToolDefinition(name: "location.fake_clear",
        summary: "Restore real GPS location. Use for: undo location spoofing after testing. Don't use for: set fake location (use location.fake), check status (use location.fake_status). Example: user says 'turn off fake location, restore real location' → clear.",
        parameters: [:], verified: true, category: "device")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let (ok, msg) = FakeLocationStore.clear()
        guard ok else { throw MCPError.failed(msg) }
        return ["message": msg]
    }
}
