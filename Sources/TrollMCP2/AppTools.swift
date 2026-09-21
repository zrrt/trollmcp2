import Foundation
import UIKit
import ObjectiveC
import AVFoundation
import BackgroundTasks

// MARK: - App 二进制依赖树（v2.9.261）
// 用途：找出"启动必加载"的 framework——主二进制 LC_LOAD_DYLIB 直接依赖的 App 内 framework
// 才是启动时加载的（注入它 ControlAgent constructor 必执行）；仅被其他 framework 依赖的
// 是懒加载（注入无效）。小红书 AppsFlyerLib/B 站 BGM 均实测为懒加载，注入后 4789 不监听。
final class AppDepsTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.deps",
        summary: "Show App dependencies (linked dylibs). Use for: check binary linkage.",
        parameters: ["bundle_id": "Target App bundle_id"],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("未找到 App: \(bundleId)")
        }
        let exec = (NSDictionary(contentsOfFile: app.path + "/Info.plist")?["CFBundleExecutable"] as? String) ?? ""
        guard !exec.isEmpty else {
            return ["bundle_id": bundleId, "error": "Info.plist 无 CFBundleExecutable"]
        }
        let mainPath = app.path + "/" + exec

        var out: [String: Any] = ["bundle_id": bundleId, "main": mainPath]
        if let mo = MachOAnalyzer.analyze(mainPath) {
            out["main_arch"] = mo.arch
            out["main_valid"] = mo.valid
            out["main_cryptID"] = mo.cryptID
            out["main_protected"] = mo.cryptID > 0
            out["main_dylibs"] = mo.dylibs
        }

        // 主二进制直接依赖的"App 内 framework"名集合
        let mainDeps = (out["main_dylibs"] as? [String]) ?? []
        let frameworksDir = app.path + "/Frameworks"
        var frameworkDeps: [[String: Any]] = []
        var bootCandidates: [String] = []
        var lazyCandidates: [String] = []

        if let items = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            for item in items.sorted() where item.hasSuffix(".framework") {
                let fwName = (item as NSString).deletingPathExtension
                let fwExe = frameworksDir + "/" + item + "/" + fwName
                var entry: [String: Any] = ["framework": item]
                if let fmo = MachOAnalyzer.analyze(fwExe) {
                    entry["arch"] = fmo.arch
                    entry["valid"] = fmo.valid
                    entry["cryptID"] = fmo.cryptID
                    entry["protected"] = fmo.cryptID > 0
                    entry["dylibs"] = fmo.dylibs
                    let isBoot = mainDeps.contains { d in d.contains(fwName) }
                    entry["boot_loaded"] = isBoot
                    if fmo.cryptID == 0 {
                        if isBoot { bootCandidates.append(fwExe) } else { lazyCandidates.append(fwExe) }
                    }
                } else {
                    entry["error"] = "MachOAnalyzer 解析失败"
                }
                frameworkDeps.append(entry)
            }
        }

        out["frameworks"] = frameworkDeps
        out["inject_boot_candidates"] = bootCandidates
        out["inject_lazy_candidates"] = lazyCandidates
        out["recommendation"] = bootCandidates.isEmpty
            ? "主二进制直接依赖里没有可注入的 App 内 framework；需 app.decrypt 砸壳后注入主二进制，或改用 HID/ui.* 界面自动化"
            : "优先注入: \(bootCandidates)"
        return out
    }
}

// v2.9.87：UIApplication.openURL 已弃用（iOS10+），统一走 open(_:options:)。
// 工具在后台线程执行，这里用信号量同步等待结果，保持 invoke 的同步语义。
private func openURLSync(_ url: URL) -> Bool {
    // v2.9.147：UIApplication.open 必须在主线程，后台调用 SIGSEGV 闪退
    return UIThreadBridge.openURL(url, timeout: 5)
}

// MARK: - App 缓存扫描

final class AppCacheInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.cache_inspect",
        summary: "Inspect App cache size. Use for: check cache usage.",
        parameters: ["limit": "Max results (default 50)", "bundle_id": "Optional: filter by specific bundle_id"],
        verified: true, category: "app_control")

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
        summary: "Clear App cache. Use for: free space.",
        parameters: ["bundle_id": "Target App bundle_id", "dry_run": "Optional: true = calculate only, no delete"], verified: true, category: "app_control")

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
        summary: "Open App by bundle_id. Use for: launch App.",
        parameters: ["bundle_id": "Target App bundle_id"],
    verified: true, category: "app_control")

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

// MARK: - Agent HTTP 通道（v2.9.103：ControlAgent v4.1 本地 HTTP 127.0.0.1:4792）
// v3/v4 时代用 NSNotification/UserDefaults 跨进程——沙盒隔离根本不通；v4.1 agent 内置
// loopback HTTP server，主 App 直连目标 App 的 agent，链路真实可用。

private let kAgentPort = 4792

private func agentHTTP(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 6) -> [String: Any]? {
    guard let url = URL(string: "http://127.0.0.1:\(kAgentPort)\(path)") else { return nil }
    var req = URLRequest(url: url)
    setHTTPMethod(method, on: &req)
    setTimeoutInterval(timeout, on: &req)
    if let body = body {
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
           (st["agent"] as? String) == "ControlAgent" {
            return true
        }
        Thread.sleep(forTimeInterval: 0.4)
    }
    return false
}

final class AppOpenAndInputTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.open_and_input",
        summary: "Open App and input text. Use for: automate App launch.",
        parameters: [
            "bundle_id": "Target App bundle_id",
            "text": "Text to input",
            "submit": "Submit after input (default false)",
            "wait": "Wait seconds for agent ready (default 8)"
        ], verified: true, category: "app_control")

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

// MARK: - 通用 App 控制（v2.9.103：直连 ControlAgent v4.1 HTTP 4792）

final class AppsControlTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.control",
        summary: "[DEPRECATED] Use control.tap/control.swipe/control.type/control.tap_text instead. Old universal control tool.",
        parameters: [
            "action": "DEPRECATED - use control.tap/control.swipe/control.type instead"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return [
            "ok": false,
            "deprecated": true,
            "message": "apps.control is deprecated. Use control.tap(x,y), control.swipe(x1,y1,x2,y2), control.type(text), or control.tap_text(\"label\") instead.",
            "hint": "These tools have fewer parameters and are easier to use."
        ]
    }
}

// MARK: - 微信消息准备

final class WeChatPrepareMessageTool: MCPTool {
    let definition = ToolDefinition(
        name: "wechat.prepare_message",
        summary: "Prepare a WeChat message (copy to clipboard and attempt to jump to WeChat)",
        parameters: [
            "text": "Message text",
            "recipient": "Optional: recipient"
        ], verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else {
            throw MCPError.invalidParams("text required")
        }
        UIThreadBridge.paste(text)
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

// MARK: - v2.9.109 TrollAgent 自身后台保活（音频静音引擎）
// 远程控制/长任务期间自动启动：AVAudioSession playback + 静音源持续输出，
// TrollAgent 切后台不被系统挂起，AI 可继续调用目标 App 的 4789。
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()
    private var engine: AVAudioEngine?
    private(set) var running = false

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let src = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in abl {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                return noErr
            }
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: fmt)
            engine.prepare()
            try engine.start()
            self.engine = engine
            running = true
        } catch {
            NSLog("[TrollAgent] BackgroundKeepAlive start failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        guard running else { return }
        engine?.stop()
        engine = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - v2.9.136 BGTask 周期刷新（与音频保活双保险）
    // iOS 调度允许时周期性唤醒 App，Audio 保活被系统回收后仍有恢复机会。
    // TrollStore 环境不受 BGTask 权限门槛限制，注册即生效。

    static let refreshID = "com.trollagent.refresh"

    static func registerBGTask() {
        guard #available(iOS 13.0, *) else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            task.expirationHandler = { task.setTaskCompleted(success: false) }
            // 唤醒后：若全局常驻开着且引擎已停（被系统回收），重启保活
            if UserDefaults.standard.bool(forKey: "trollagent.keepalive_global") {
                BackgroundKeepAlive.shared.start()
            }
            scheduleRefresh()
            task.setTaskCompleted(success: true)
        }
    }

    static func scheduleRefresh() {
        guard #available(iOS 13.0, *) else { return }
        guard UserDefaults.standard.bool(forKey: "trollagent.keepalive_global") else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancelRefresh() {
        guard #available(iOS 13.0, *) else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
    }
}

// 跨进程切换目标 App 的真后台保活（ControlAgent 监听同名字 Darwin 通知）
func postKeepAliveNotification(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: "trollagent.keepalive")
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFNotificationName("com.trollagent.keepalive" as CFString),
                                         nil, nil, true)
}
