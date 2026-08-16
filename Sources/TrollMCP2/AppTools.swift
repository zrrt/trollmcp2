import Foundation
import UIKit
import ObjectiveC

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
            opened = UIApplication.shared.openURL(url)
        }
        if !opened {
            opened = LSAppWorkspaceOpen(bundleId: bid)
        }

        AuditLog.shared.log("apps.open", detail: bid)
        return ["bundle_id": bid, "opened": opened, "name": app.name]
    }
}

// MARK: - 启动并输入（依赖注入代理，这里做状态上报）

final class AppOpenAndInputTool: MCPTool {
    let definition = ToolDefinition(
        name: "apps.open_and_input",
        summary: "打开指定 App 并提交输入命令（需目标已注入 TrollMCPAgent）",
        parameters: [
            "bundle_id": "目标 App Bundle ID",
            "text": "要输入的文本",
            "submit": "是否提交（默认 false）"
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

        let submit = (params["submit"] as? Bool) ?? false
        let status = InjectionManager.shared.inspect(bid)
        let injected = (status["injected"] as? Bool) ?? false

        var opened = false
        if let url = URL(string: "\(bid)://") {
            opened = UIApplication.shared.openURL(url)
        }
        if !opened {
            opened = LSAppWorkspaceOpen(bundleId: bid)
        }

        // 将命令写入共享队列，供注入代理读取
        if injected {
            var queue = UserDefaults.standard.array(forKey: "trollmcp2.input_queue_\(bid)") as? [[String: Any]] ?? []
            queue.append(["text": text, "submit": submit, "ts": Date().timeIntervalSince1970])
            UserDefaults.standard.set(queue, forKey: "trollmcp2.input_queue_\(bid)")
        }

        AuditLog.shared.log("apps.open_and_input", detail: "\(bid) injected=\(injected)")
        return [
            "bundle_id": bid,
            "opened": opened,
            "injected": injected,
            "agentStatus": injected ? (submit ? "filled" : "pending") : "no_agent",
            "text": text
        ]
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
            opened = UIApplication.shared.openURL(url)
        }
        if !opened, let url = URL(string: "weixin://") {
            opened = UIApplication.shared.openURL(url)
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
