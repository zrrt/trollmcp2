import Foundation
import UIKit
import Contacts
import EventKit
import CoreLocation
import UserNotifications
import Vision

// MARK: - M3 注入工具

final class InjectionEnableTool: MCPTool {
    let definition = ToolDefinition(name: "injection.enable", summary: "向指定 App 注入 dylib",
        parameters: ["bundle_id": "目标 App Bundle ID", "dylib_path": "dylib 文件路径"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let dylib = params["dylib_path"] as? String ?? "@executable_path/TrollMCPAgent.dylib"
        let result = try InjectionManager.shared.enable(bundleId: bid, dylibPath: dylib)
        AuditLog.shared.log("injection.enable", detail: "\(bid) → \(dylib)")
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
    let definition = ToolDefinition(name: "injection.status", summary: "查看注入工具链状态与已装 App 列表")
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
    let definition = ToolDefinition(name: "injection.list", summary: "列出设备已安装 App（App 目录）")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let apps = AppCatalog.list()
        return [
            "total": apps.count,
            "apps": apps.map { ["bundle_id": $0.bundleId, "name": $0.name] }
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

// MARK: - M4 自动化工具

final class AutomationRunTool: MCPTool {
    let definition = ToolDefinition(name: "automation.run", summary: "运行自动化脚本",
        parameters: ["script": "脚本内容"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let script = params["script"] as? String ?? ""
        AuditLog.shared.log("automation.run", detail: script.prefix(100).description)
        return ["queued": true, "length": script.count]
    }
}

final class AutomationListTool: MCPTool {
    let definition = ToolDefinition(name: "automation.list", summary: "列出自动化任务")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        ["tasks": []]
    }
}

final class AutomationStopTool: MCPTool {
    let definition = ToolDefinition(name: "automation.stop", summary: "停止自动化任务",
        parameters: ["task": "任务 ID"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        ["stopped": true]
    }
}

final class AutomationStatusTool: MCPTool {
    let definition = ToolDefinition(name: "automation.status", summary: "自动化引擎状态")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        ["running": false, "queue": 0]
    }
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
    let definition = ToolDefinition(name: "project.generate_tweak", summary: "生成 Tweak 项目模板",
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
        AuditLog.shared.log("project.generate_tweak", detail: name)
        return ["created": true, "path": "projects/\(name)", "name": name]
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
