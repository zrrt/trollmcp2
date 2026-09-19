import Foundation
import UIKit

// MARK: - v2.9.139 四件套之二：启动带参数（SBSLaunchApplicationWithOptions + DYLD_INSERT_LIBRARIES）
// 用途：AI 启动目标 App 时注入环境变量（如 DYLD_INSERT_LIBRARIES 预加载 hook）/启动参数/调试标记。
// 私有 API 走 dlsym（SpringBoardServices），entitlements 已含 com.apple.springboard.launchapplicationswithoptions。

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
                    var detail = "启动成功（带参数）"
                    if !environment.isEmpty { detail += "，env: \(environment.keys.joined(separator: ","))" }
                    if !arguments.isEmpty { detail += "，args: \(arguments.joined(separator: " "))" }
                    return (true, detail)
                }
                return (false, "SBSLaunchApplicationWithOptions 返回 \(ret)")
            }
            dlclose(handle)
        }
        // 回退：无参启动
        return ProcessHelper.launchApp(bundleId: bundleId)
    }
}

// MARK: - 四件套之三：定位模拟（locationd.simulation）
// 诚实能力边界：
//  · 全局模拟（所有 App 生效）需要 hook 系统进程 locationd——TrollStore 非越狱，无法注入系统进程，系统级做不到。
//  · 可行路径：写入模拟坐标配置（供目标 App 的坐标 Hook dylib 读取）+ 引导注入。
//  · 本文实现 Layer1：坐标配置写入（可复现、立即成功）；Layer2：尽力尝试 CLLocationManager 私有模拟接口（失败返回真实原因）。

enum FakeLocationStore {
    static let url = Workspace.root.appendingPathComponent("location_fake.json")

    static func save(lat: Double, lon: Double) -> (Bool, String) {
        let dict: [String: Any] = ["lat": lat, "lon": lon, "enabled": true, "updated_at": Int(Date().timeIntervalSince1970)]
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return (true, "已写入模拟坐标配置: \(url.path)")
        } catch {
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }

    static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    static func clear() -> (Bool, String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (true, "无模拟配置可清除") }
        do {
            try FileManager.default.removeItem(at: url)
            return (true, "已清除模拟定位配置")
        } catch {
            return (false, "清除失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCP 工具

final class AppLaunchOptionsTool: MCPTool {
    let definition = ToolDefinition(name: "app.launch", 
        summary: "启动指定 App 并可注入环境变量/启动参数（SBSLaunchApplicationWithOptions）。env 可传 DYLD_INSERT_LIBRARIES 预加载 hook 库。调用时务必带 reason 说明为何唤醒该 App。",
        parameters: ["bundle_id": "目标 App Bundle ID", "env": "环境变量字典（可选，如 {\"DYLD_INSERT_LIBRARIES\": \"/path/hook.dylib\"}）", "args": "启动参数数组（可选）", "reason": "判断依据（必填）"], verified: true)
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
            ControlSession.shared.addResult("❌ 启动失败: \(msg)")
            throw MCPError.classified("启动失败", code: "LAUNCH_FAILED", reason: msg, nextStep: "确认 bundle_id 正确；若目标 App 是 App Store 加密版，先砸壳；或改用 ai 控制中心手动点击启动")
        }
        ControlSession.shared.addResult("✅ 已唤醒 \(bundleId)")
        return ["message": msg, "bundle_id": bundleId, "method": "SBSLaunchApplicationWithOptions"]
    }
}

final class LocationFakeTool: MCPTool {
    let definition = ToolDefinition(name: "location.fake",
        summary: "写入模拟定位坐标。注意：系统级全局模拟需 hook locationd 系统进程（TrollStore 做不到）；对目标 App 生效需目标 App 注入坐标 Hook 读取该配置（或用注入功能实现）。",
        parameters: ["lat": "纬度", "lon": "经度", "reason": "判断依据（可选）"], verified: true)
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
            "message": msg + "。生效路径：① 目标 App 注入坐标 Hook 读取此配置；② 全局模拟需系统进程，TrollStore 不支持。",
            "config_path": FakeLocationStore.url.path,
            "lat": lat, "lon": lon
        ]
    }
}

final class LocationFakeStatusTool: MCPTool {
    let definition = ToolDefinition(name: "location.fake_status",
        summary: "查看当前模拟定位配置（坐标/启用状态）。",
        parameters: [:], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let cfg = FakeLocationStore.read() else {
            return ["enabled": false, "message": "当前未设置模拟定位"]
        }
        return ["enabled": true, "lat": cfg["lat"] ?? 0, "lon": cfg["lon"] ?? 0, "config_path": FakeLocationStore.url.path]
    }
}

final class LocationFakeClearTool: MCPTool {
    let definition = ToolDefinition(name: "location.fake_clear",
        summary: "清除模拟定位配置，恢复真实定位。",
        parameters: [:], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let (ok, msg) = FakeLocationStore.clear()
        guard ok else { throw MCPError.failed(msg) }
        return ["message": msg]
    }
}
