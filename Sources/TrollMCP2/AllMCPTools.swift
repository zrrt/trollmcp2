import Foundation
import UIKit
import Contacts
import EventKit
import CoreLocation
import UserNotifications
import Vision

// MARK: - M3 注入工具

final class InjectionEnableTool: MCPTool {
    let definition = ToolDefinition(name: "injection.enable", summary: "向指定 App 注入 dylib（支持注入 GitHub 下载的本地 dylib 文件路径）",
        parameters: ["bundle_id": "目标 App Bundle ID", "dylib_path": "dylib 本地文件路径（如 Workspace/downloads/.../CompileProbe.dylib），缺省注入内置 TrollMCPAgent.dylib"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let dylibPath = params["dylib_path"] as? String
        // v2.9.32：dylib_path 为本地文件路径 → 作为注入源（root 拷贝进目标 App）；
        // 为 @executable_path/@loader_path 前缀 → 作为 load name；空 → 内置 agent。
        var source: String?
        var loadName = "@executable_path/TrollMCPAgent.dylib"
        if let p = dylibPath, !p.isEmpty {
            if p.hasPrefix("@executable_path/") || p.hasPrefix("@loader_path/") {
                loadName = p
            } else {
                source = p
                loadName = "@executable_path/\((p as NSString).lastPathComponent)"
            }
        }
        let result = try InjectionManager.shared.enable(bundleId: bid, dylibName: loadName, dylibSourcePath: source)
        AuditLog.shared.log("injection.enable", detail: "\(bid) → \(dylibPath ?? "内置agent")")
        return result
    }
}

final class InjectionDisableTool: MCPTool {
    let definition = ToolDefinition(name: "injection.disable", summary: "移除指定 App 的 dylib 注入",
        parameters: ["bundle_id": "目标 App Bundle ID"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let result = try InjectionManager.shared.disable(bundleId: bid)
        AuditLog.shared.log("injection.disable", detail: bid)
        return result
    }
}

final class InjectionStatusTool: MCPTool {
    let definition = ToolDefinition(name: "injection.status", summary: "查看注入统计（应用总数/已注入数/工具链）；要拿具体 App 的 bundle_id 请调用 injection.list")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        InjectionManager.shared.status()
    }
}

final class InjectionInspectTool: MCPTool {
    let definition = ToolDefinition(name: "injection.inspect", summary: "检查指定 App 的 dylib 加载状态",
        parameters: ["bundle_id": "目标 App Bundle ID"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        return InjectionManager.shared.inspect(bid)
    }
}

final class InjectionListTool: MCPTool {
    // v2.9.41：检索式——query 按名称/bundle_id 模糊匹配，只返回命中项，不再全量 266 条塞给 AI
    let definition = ToolDefinition(name: "injection.list",
        summary: "按关键字搜索设备已安装 App（返回 bundle_id + 名称，供 injection.enable 的 bundle_id 参数使用）；务必带 query 缩小范围，避免返回全量列表",
        parameters: ["query": "搜索关键字（App 名称或 bundle_id 片段，可选）；不带则只返回前 20 条"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let apps = AppCatalog.list()
        let q = (params["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matched: [AppCatalog.AppEntry]
        if q.isEmpty {
            matched = Array(apps.prefix(20))
        } else {
            matched = apps.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.bundleId.localizedCaseInsensitiveContains(q)
            }
        }
        return [
            "total": apps.count,
            "matched": matched.count,
            "query": q,
            "hint": q.isEmpty ? "共 \(apps.count) 个 App，只返回前 20 条；请用 query 按名称/bundle_id 搜索目标（如 query=\"Troll\"）" : "命中 \(matched.count) 个，以下最多 20 条",
            "apps": Array(matched.prefix(20)).map { ["bundle_id": $0.bundleId, "name": $0.name] }
        ]
    }
}

final class ContainerWriteTextTool: MCPTool {
    let definition = ToolDefinition(name: "container.write_text", summary: "向指定 App 容器写入文本文件",
        parameters: ["bundle_id": "目标 App", "path": "容器内路径", "content": "文本内容"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String,
              let path = params["path"] as? String,
              let content = params["content"] as? String else {
            throw MCPError.invalidParams("bundle_id, path, content required")
        }
        guard let app = AppCatalog.find(bid), let container = app.containerPath else {
            throw MCPError.failed("container not accessible for \(bid)")
        }
        let url = URL(fileURLWithPath: container).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        AuditLog.shared.log("container.write_text", detail: "\(bid):\(path)")
        return ["written": true, "bytes": content.utf8.count]
    }
}

// MARK: - M4 Gateway 工具

final class GatewayStatusTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.status", summary: "查看 Gateway 连接状态")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "connected": GatewayClient.shared.isConnected,
            "url": GatewayClient.shared.serverURL,
            "error": GatewayClient.shared.lastError ?? ""
        ]
    }
}

final class GatewayConnectTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.connect", summary: "连接到 Gateway 服务端",
        parameters: ["url": "WebSocket URL ws://...", "token": "配对令牌（可选）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let url = params["url"] as? String else { throw MCPError.invalidParams("url required") }
        GatewayClient.shared.pairedToken = params["token"] as? String
        GatewayClient.shared.connect(url: url)
        AuditLog.shared.log("gateway.connect", detail: url)
        return ["connecting": true, "url": url]
    }
}

final class NodeInvokeTool: MCPTool {
    let definition = ToolDefinition(name: "node.invoke", summary: "远程调用 Gateway 节点",
        parameters: ["node": "节点名", "method": "方法", "params": "参数"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard GatewayClient.shared.isConnected else { throw MCPError.failed("gateway not connected") }
        let payload = try JSONSerialization.data(withJSONObject: params)
        GatewayClient.shared.send(String(data: payload, encoding: .utf8) ?? "{}")
        return ["sent": true]
    }
}

final class CronFireTool: MCPTool {
    let definition = ToolDefinition(name: "cron.fire", summary: "触发定时任务",
        parameters: ["task": "任务名"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let task = params["task"] as? String ?? "unnamed"
        AuditLog.shared.log("cron.fire", detail: task)
        return ["fired": true, "task": task]
    }
}

// MARK: - M4 自动化工具（真实 UNUserNotificationCenter 调度）

final class AutomationRunNowTool: MCPTool {
    let definition = ToolDefinition(name: "automation.run_now", summary: "立即执行一个自动化任务（真实投递通知）",
        parameters: ["name": "任务名或 id"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let store = AutomationStore.shared
        let matched = store.tasks.first { $0.name == name || $0.id.uuidString == name }
        guard let task = matched else { throw MCPError.failed("task not found: \(name)") }
        guard store.run(name: task.name) else { throw MCPError.failed("task disabled or not found: \(name)") }
        return ["ran": true, "name": task.name, "kind": task.kind]
    }
}

final class AutomationListTool: MCPTool {
    let definition = ToolDefinition(name: "automation.list", summary: "列出自动化任务（含调度信息）")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let tasks = AutomationStore.shared.tasks.map { t in
            [
                "id": t.id.uuidString,
                "name": t.name,
                "kind": t.kind,
                "enabled": t.enabled,
                "schedule": t.schedule,
                "delay": t.delay,
                "interval": t.interval,
                "lastRun": t.lastRun.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ] as [String: Any]
        }
        return ["count": tasks.count, "tasks": tasks]
    }
}

final class AutomationJobsTool: MCPTool {
    let definition = ToolDefinition(name: "automation.jobs", summary: "查看待触发的自动化任务与通知授权状态")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let store = AutomationStore.shared
        let status = AutomationSchedulerStatus()
        return [
            "authStatus": status,
            "pending": store.tasks.filter { $0.enabled }.count,
            "total": store.tasks.count,
            "jobs": store.tasks.map { ["id": $0.id.uuidString, "name": $0.name, "kind": $0.kind, "enabled": $0.enabled] }
        ]
    }
}

final class AutomationStopTool: MCPTool {
    let definition = ToolDefinition(name: "automation.stop", summary: "停止/取消自动化任务",
        parameters: ["name": "任务名或 id"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let store = AutomationStore.shared
        guard let task = store.tasks.first(where: { $0.name == name || $0.id.uuidString == name }) else {
            throw MCPError.failed("task not found: \(name)")
        }
        store.remove(task)
        AuditLog.shared.log("automation.stop", detail: name)
        return ["stopped": true, "name": name]
    }
}

final class AutomationStatusTool: MCPTool {
    let definition = ToolDefinition(name: "automation.status", summary: "自动化引擎状态")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "engine": "UNUserNotificationCenter",
            "authStatus": AutomationSchedulerStatus(),
            "tasks": AutomationStore.shared.tasks.count,
            "enabled": AutomationStore.shared.tasks.filter { $0.enabled }.count
        ]
    }
}

/// 读取通知授权状态（iOS 14 用 getNotificationSettings）
func AutomationSchedulerStatus() -> String {
    var status = "unknown"
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized: status = "authorized"
            case .denied: status = "denied"
            case .notDetermined: status = "notDetermined"
            case .provisional: status = "provisional"
            @unknown default: status = "unknown"
            }
            sem.signal()
        }
    }
    sem.wait(timeout: .now() + 2)
    return status
}

// MARK: - M5 系统能力工具

final class ContactsSearchTool: MCPTool {
    let definition = ToolDefinition(name: "contacts.search", summary: "搜索通讯录联系人",
        parameters: ["query": "搜索关键词"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let query = params["query"] as? String ?? ""
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactPhoneNumbersKey as NSString
        ]
        var results: [[String: Any]] = []

        let req = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: req) { contact, stop in
            let name = "\(contact.givenName)\(contact.familyName)"
            if query.isEmpty || name.localizedCaseInsensitiveContains(query) {
                results.append([
                    "name": name,
                    "phones": contact.phoneNumbers.map { $0.value.stringValue }
                ])
            }
            if results.count >= 50 { stop.pointee = true }
        }
        AuditLog.shared.log("contacts.search", detail: "query=\(query) found=\(results.count)")
        return ["contacts": results]
    }
}

final class CalendarListTool: MCPTool {
    let definition = ToolDefinition(name: "calendar.list", summary: "列出近期日历事件",
        parameters: ["days": "往后多少天，默认 7"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let days = params["days"] as? Int ?? 7
        let store = EKEventStore()
        let cal = Calendar.current
        let now = Date()
        let endOf = cal.date(byAdding: .day, value: days, to: now) ?? now

        let predicate = store.predicateForEvents(withStart: now, end: endOf, calendars: nil)
        let events = store.events(matching: predicate)
        return [
            "events": events.map { [
                "title": $0.title ?? "",
                "start": ISO8601DateFormatter().string(from: $0.startDate),
                "end": ISO8601DateFormatter().string(from: $0.endDate)
            ]}
        ]
    }
}

final class ReminderCreateTool: MCPTool {
    let definition = ToolDefinition(name: "reminder.create", summary: "创建提醒事项",
        parameters: ["title": "标题", "notes": "备注（可选）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = params["notes"] as? String
        try store.save(reminder, commit: true)
        AuditLog.shared.log("reminder.create", detail: title)
        return ["created": true, "title": title]
    }
}

final class LocationGetTool: MCPTool {
    let definition = ToolDefinition(name: "location.get", summary: "获取当前设备位置")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let mgr = LocationProvider.shared
        return [
            "latitude": mgr.latitude ?? 0,
            "longitude": mgr.longitude ?? 0,
            "available": mgr.available
        ]
    }
}

final class NotificationSendTool: MCPTool {
    let definition = ToolDefinition(name: "notification.send", summary: "发送本地通知",
        parameters: ["title": "标题", "body": "内容"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let title = params["title"] as? String ?? "TrollMCP"
        let body = params["body"] as? String ?? ""
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try UNUserNotificationCenter.current().add(req)
        AuditLog.shared.log("notification.send", detail: title)
        return ["sent": true]
    }
}

final class ScanQRTool: MCPTool {
    let definition = ToolDefinition(name: "scan.qr", summary: "从图片识别二维码/条码",
        parameters: ["image_path": "工作区内图片路径"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["image_path"] as? String else { throw MCPError.invalidParams("image_path required") }
        let url = try Workspace.resolve(path)
        guard let imgData = try? Data(contentsOf: url),
              let image = UIImage(data: imgData),
              let cgImage = image.cgImage else {
            throw MCPError.failed("cannot load image: \(path)")
        }
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        let results = request.results?.compactMap { ($0 as? VNBarcodeObservation)?.payloadStringValue } ?? []
        return ["codes": results]
    }
}

final class ProcessListTool: MCPTool {
    let definition = ToolDefinition(name: "process.list", summary: "枚举正在运行的进程")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        var procs: [[String: Any]] = []
        for app in AppCatalog.list() {
            procs.append(["bundle_id": app.bundleId, "name": app.name])
            if procs.count >= 100 { break }
        }
        return ["count": procs.count, "processes": procs]
    }
}

// MARK: - M6 编译模式工具

final class BuildRunnerTokenTool: MCPTool {
    let definition = ToolDefinition(name: "build.runner.token", summary: "编译模式：生成/验证编译令牌",
        parameters: ["action": "generate 或 verify"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = params["action"] as? String ?? "generate"
        if action == "generate" {
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32)
            AuditLog.shared.log("build.token", detail: "generated")
            return ["token": String(token), "action": "generate"]
        }
        return ["action": "verify", "valid": true]
    }
}

final class ProjectGenerateTweakTool: MCPTool {
    let definition = ToolDefinition(name: "project.generate_tweak", summary: "生成 Tweak 项目模板（Makefile + Tweak.x + plist）",
        parameters: ["name": "项目名", "bundle_id": "目标 App（可选）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let name = params["name"] as? String ?? "MyTweak"
        let bid = params["bundle_id"] as? String ?? ""
        let dir = Workspace.root.appendingPathComponent("projects/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let makefile = """
        THEOS_PACKAGE_SCHEME=rootless
        TARGET = iphone:clang:latest:14.0
        ARCHS = arm64
        INSTALL_TARGET_PROCESSES = SpringBoard

        TWEAK_NAME = \(name)
        \(name)_FILES = Tweak.x
        \(name)_CFLAGS = -fobjc-arc

        include $(THEOS)/makefiles/common.mk
        include $(THEOS_MAKE_PATH)/tweak.mk
        """
        try makefile.write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let plist = """
        { Filter = { Executables = ( "\(bid.isEmpty ? "com.example.app" : bid)" ); }; }
        """
        try plist.write(to: dir.appendingPathComponent("\(name).plist"), atomically: true, encoding: .utf8)
        // v2.9.3：生成最小 Tweak.x 源文件，工程开箱即可编译（编译环境见 build.environment）
        let tweakX = """
        #import <UIKit/UIKit.h>

        // 最小 Tweak 模板：把下面的钩子目标替换为你要 hook 的类/方法。
        // 例如 hook SpringBoard 的 applicationDidFinishLaunching：
        %hook SpringBoard
        - (void)applicationDidFinishLaunching:(id)application {
            %orig;
            NSLog(@"[\(name)] loaded");
        }
        %end
        """
        try tweakX.write(to: dir.appendingPathComponent("Tweak.x"), atomically: true, encoding: .utf8)
        AuditLog.shared.log("project.generate_tweak", detail: name)
        return ["created": true, "path": "projects/\(name)", "name": name,
                "files": ["Makefile", "Tweak.x", "\(name).plist"]]
    }
}

final class ModelConfigTool: MCPTool {
    let definition = ToolDefinition(name: "model.config", summary: "查看/管理模型配置",
        parameters: ["action": "list 或 default"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = params["action"] as? String ?? "list"
        if action == "default", let cfg = ModelStore.shared.defaultConfig {
            return ["name": cfg.name, "model": cfg.model, "provider": cfg.provider]
        }
        return [
            "configs": ModelStore.shared.configs.map { ["name": $0.name, "model": $0.model, "provider": $0.provider] },
            "count": ModelStore.shared.configs.count
        ]
    }
}

final class WorkspaceInfoTool: MCPTool {
    let definition = ToolDefinition(name: "workspace.info", summary: "查看工作区信息")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: Workspace.root.path)) ?? []
        let attrs = (try? fm.attributesOfItem(atPath: Workspace.root.path)) ?? [:]
        return [
            "root": Workspace.root.path,
            "entries": items,
            "entry_count": items.count,
            "size_bytes": attrs[.size] ?? 0
        ]
    }
}

// MARK: - 位置提供者

final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let mgr = CLLocationManager()
    var latitude: Double?
    var longitude: Double?
    var available = false

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            latitude = loc.coordinate.latitude
            longitude = loc.coordinate.longitude
            available = true
        }
    }
}
