import Foundation
import UIKit
import ObjectiveC

// v2.9.87：UIApplication.openURL 已弃用（iOS10+），统一走 open(_:options:)。
// 工具在后台线程执行，这里用信号量同步等待结果，保持 invoke 的同步语义。
private func openURLSync(_ url: URL) -> Bool {
    var opened = false
    let sem = DispatchSemaphore(value: 0)
    UIApplication.shared.open(url, options: [:]) { success in
        opened = success
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    return opened
}

// MARK: - App 缓存扫描

final class AppCacheInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.cache_inspect",
        summary: "扫描已安装应用的缓存大小",
        parameters: ["limit": "返回条数上限，默认 50", "bundle_id": "可选：只查某个 Bundle ID"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let limit = params["limit"] as? Int ?? 50
        let target = params["bundle_id"] as? String

        var results: [[String: Any]] = []
        let apps = target != nil ? AppCatalog.list().filter { $0.bundleId == target } : AppCatalog.list()

        for app in apps {
            guard let container = app.containerPath else { continue }
            let caches = URL(fileURLWithPath: container).appendingPathComponent("Library/Caches")
            let tmp = URL(fileURLWithPath: container).appendingPathComponent("tmp")
            let cachesSize = AppCacheScanner.directorySize(caches)
            let tmpSize = AppCacheScanner.directorySize(tmp)
            let total = cachesSize + tmpSize
            results.append([
                "bundle_id": app.bundleId,
                "name": app.name,
                "caches_bytes": cachesSize,
                "tmp_bytes": tmpSize,
                "total_bytes": total,
                "total_readable": AppCacheScanner.humanSize(total)
            ])
            if results.count >= limit { break }
        }

        results.sort {
            (($0["total_bytes"] as? Int) ?? 0) > (($1["total_bytes"] as? Int) ?? 0)
        }

        AuditLog.shared.log("apps.cache_inspect", detail: "scanned \(results.count) apps")
        return [
            "count": results.count,
            "apps": results
        ]
    }
}

// MARK: - App 缓存清理

final class AppCacheClearTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.cache_clear",
        summary: "清理指定 App 的 Library/Caches 与 tmp 目录",
        parameters: ["bundle_id": "目标 App Bundle ID", "dry_run": "可选：true 只计算不删除"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bid), let container = app.containerPath else {
            throw MCPError.failed("container not accessible for \(bid)")
        }
        let dryRun = (params["dry_run"] as? Bool) ?? false
        let fm = FileManager.default
        let caches = URL(fileURLWithPath: container).appendingPathComponent("Library/Caches")
        let tmp = URL(fileURLWithPath: container).appendingPathComponent("tmp")

        var cleared = 0
        var freedBytes: Int64 = 0
        var errors: [String] = []

        for url in [caches, tmp] {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                let before = AppCacheScanner.directorySize(url)
                if !dryRun {
                    try fm.removeItem(at: url)
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                }
                freedBytes += Int64(before)
                cleared += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        AuditLog.shared.log("apps.cache_clear", detail: "\(bid) dry_run=\(dryRun)")
        return [
            "bundle_id": bid,
            "cleared_dirs": cleared,
            "freed_bytes": freedBytes,
            "freed_readable": AppCacheScanner.humanSize(Int(freedBytes)),
            "dry_run": dryRun,
            "errors": errors
        ]
    }
}

// MARK: - 缓存扫描辅助

enum AppCacheScanner {
    static func directorySize(_ url: URL) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var size = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let fileURL as URL in enumerator {
                if let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let s = attrs.fileSize {
                    size += s
                }
            }
        }
        return size
    }

    static func humanSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - 启动 App

final class AppOpenTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.open",
        summary: "打开指定 App",
        parameters: ["bundle_id": "目标 App Bundle ID"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bid) else {
            throw MCPError.failed("app not found: \(bid)")
        }

        var opened = false
        if let url = URL(string: "\(bid)://") {
            opened = openURLSync(url)
        }
        if !opened {
            opened = LSAppWorkspaceOpen(bundleId: bid)
        }

        AuditLog.shared.log("apps.open", detail: bid)
        return ["bundle_id": bid, "opened": opened, "name": app.name]
    }
}

// MARK: - 启动并输入（依赖注入代理，这里做状态上报）

// MARK: - Agent HTTP 通道（v2.9.103：TrollMCPAgent v4.1 本地 HTTP 127.0.0.1:4792）
// v3/v4 时代用 NSNotification/UserDefaults 跨进程——沙盒隔离根本不通；v4.1 agent 内置
// loopback HTTP server，主 App 直连目标 App 的 agent，链路真实可用。

private let kAgentPort = 4792

private func agentHTTP(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 6) -> [String: Any]? {
    guard let url = URL(string: "http://127.0.0.1:\(kAgentPort)\(path)") else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = timeout
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    let sem = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    let task = URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = obj
        }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return result
}

private func waitAgentReady(timeout: TimeInterval = 8) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let st = agentHTTP("GET", "/status"),
           (st["agent"] as? String) == "TrollMCPAgent" {
            return true
        }
        Thread.sleep(forTimeInterval: 0.4)
    }
    return false
}

final class AppOpenAndInputTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.open_and_input",
        summary: "打开指定 App，等待 TrollMCPAgent 就绪后输入文本（v4.1 HTTP 链路）",
        parameters: [
            "bundle_id": "目标 App Bundle ID",
            "text": "要输入的文本",
            "submit": "是否提交（默认 false）",
            "wait": "等待 agent 就绪秒数，默认 8"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String,
              let text = params["text"] as? String else {
            throw MCPError.invalidParams("bundle_id and text required")
        }
        guard AppCatalog.find(bid) != nil else {
            throw MCPError.failed("app not found: \(bid)")
        }

        var opened = false
        if let url = URL(string: "\(bid)://") {
            opened = openURLSync(url)
        }
        if !opened {
            opened = LSAppWorkspaceOpen(bundleId: bid)
        }

        // 等待注入的 agent HTTP 就绪（目标 App 启动后 ~1s 起服务）
        let wait = (params["wait"] as? Double) ?? 8
        let ready = waitAgentReady(timeout: wait)
        var agentStatus = "no_agent"
        var agentResult: [String: Any]?
        if ready {
            let r = agentHTTP("POST", "/type", body: ["text": text])
            agentResult = r
            let ok = (r?["success"] as? Bool) ?? false
            let typed = ((r?["data"] as? [String: Any])?["typed"] as? Bool) ?? false
            agentStatus = ok && typed ? "filled" : "agent_error"
        }

        AuditLog.shared.log("apps.open_and_input", detail: "\(bid) opened=\(opened) status=\(agentStatus)")
        return [
            "bundle_id": bid,
            "opened": opened,
            "agentStatus": agentStatus,
            "agentResult": agentResult ?? [:],
            "text": text
        ]
    }
}

// MARK: - 通用 App 控制（v2.9.103：直连 TrollMCPAgent v4.1 HTTP 4792）

final class AppsControlTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.control",
        summary: "控制已注入 TrollMCPAgent 的 App（HTTP 直连）：status/ui_tree/tap/swipe/type/scroll",
        parameters: [
            "bundle_id": "目标 App Bundle ID（提示用）",
            "action": "status | ui_tree | tap | swipe | type | scroll",
            "x": "tap 坐标 x",
            "y": "tap 坐标 y",
            "x1": "swipe 起点 x",
            "y1": "swipe 起点 y",
            "x2": "swipe 终点 x",
            "y2": "swipe 终点 y",
            "duration": "swipe 时长秒",
            "text": "type 文本",
            "direction": "scroll 方向 up/down/left/right"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("action required (status/ui_tree/tap/swipe/type/scroll)")
        }
        var body: [String: Any] = [:]
        for (k, v) in params where k != "bundle_id" && k != "action" {
            body[k] = v
        }
        body["action"] = action
        guard let r = agentHTTP("POST", "/command", body: body) else {
            return ["success": false, "error": "agent HTTP 不可达：目标 App 未注入 TrollMCPAgent v4.1 或未在前台运行"]
        }
        var out = r
        if let bid = params["bundle_id"] as? String { out["bundle_id"] = bid }
        return out
    }
}

// MARK: - 微信消息准备

final class WeChatPrepareMessageTool: MCPTool {
    let definition = ToolDefinition(
        name: "wechat.prepare_message",
        summary: "准备微信消息（复制到剪贴板并尝试跳转微信）",
        parameters: [
            "text": "消息文本",
            "recipient": "可选：接收人"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else {
            throw MCPError.invalidParams("text required")
        }
        UIPasteboard.general.string = text
        let recipient = params["recipient"] as? String ?? ""
        var opened = false
        if !recipient.isEmpty, let url = URL(string: "weixin://dl/chat?\(recipient.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
            opened = openURLSync(url)
        }
        if !opened, let url = URL(string: "weixin://") {
            opened = openURLSync(url)
        }
        AuditLog.shared.log("wechat.prepare_message", detail: "len=\(text.count)")
        return ["copied": true, "opened_wechat": opened, "text_length": text.count]
    }
}

// MARK: - LSApplicationWorkspace 启动

private func LSAppWorkspaceOpen(bundleId: String) -> Bool {
    guard let wsClass = NSClassFromString("LSApplicationWorkspace") else { return false }
    guard let m = class_getClassMethod(wsClass, NSSelectorFromString("defaultWorkspace")) else { return false }
    let fn = unsafeBitCast(method_getImplementation(m), to: (@convention(c) (AnyClass, Selector) -> AnyObject?).self)
    guard let ws = fn(wsClass, NSSelectorFromString("defaultWorkspace")) else { return false }

    let sel = NSSelectorFromString("openApplicationWithBundleID:")
    guard let method = class_getInstanceMethod(object_getClass(ws), sel) else { return false }
    let imp = method_getImplementation(method)
    typealias OpenFn = @convention(c) (AnyObject, Selector, NSString) -> Bool
    let openFn = unsafeBitCast(imp, to: OpenFn.self)
    return openFn(ws, sel, bundleId as NSString)
}
