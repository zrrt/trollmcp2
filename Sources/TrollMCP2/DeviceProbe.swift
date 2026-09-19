import Foundation
import UIKit
import Security

// MARK: - 设备环境自检（"检测手机"核心层）

/// 在 iPhone 上自检运行环境：TrollStore/TrollFools 是否可用、task_for_pid 与
/// App 容器任意读写权限是否生效、内置注入二进制可否执行、amfid 绕过是否推断生效。
final class DeviceProbe: ObservableObject {
    static let shared = DeviceProbe()
    // v2.9.149：探测串行锁——页面 onAppear 与启动后台探测可能并发 run()，
    // 同时枚举应用/写探针文件导致 SIGSEGV
    private let runLock = NSLock()

    struct Check: Identifiable {
        let id = UUID()
        let label: String
        let passed: Bool
        let detail: String
        let infoOnly: Bool  // v2.9.66：信息提醒项，不显示 ✔/✘，只显示 ℹ️，不影响整体就绪状态
    }

    struct Report {
        let deviceName: String
        let model: String
        let systemVersion: String
        let vendorID: String
        let trollStore: Bool
        let trollFools: Bool
        let taskForPid: Bool
        let containerWrite: Bool
        let injectionBinaries: [String: Bool]
        let amfidBypassInferred: Bool
        let entitlementsOK: Bool
        let rootDiagnosis: [String: Any]?
        let checks: [Check]
        let ready: Bool
        // v2.9.67：增强设备信息
        let deviceModelIdentifier: String  // 如 iPhone14,5
        let deviceModelName: String        // 如 iPhone 13
        let storageTotal: String           // 总存储
        let storageFree: String            // 可用存储
        let memoryTotal: String            // 总内存
        let screenSize: String             // 屏幕分辨率
        let appCount: Int                  // 已安装 App 数量
        let workspaceSize: String          // 工作区大小
        let batteryLevel: String           // 电池电量
    }

    @Published var lastReport: Report?

    // MARK: Mach 调用（避免 import mach 类型，直接用 UInt32 别名）

    @_silgen_name("task_for_pid")
    public func tm_task_for_pid(_ task: UInt32, _ pid: Int32, _ target_task: UnsafeMutablePointer<UInt32>) -> Int32

    @_silgen_name("mach_task_self")
    public func tm_mach_task_self() -> UInt32

    @_silgen_name("mach_port_deallocate")
    public func tm_mach_port_deallocate(_ task: UInt32, _ name: UInt32) -> Int32

    // MARK: 公开入口

    func run() -> Report {
        runLock.lock()
        defer { runLock.unlock() }
        let deviceName = UIDevice.current.name
        let model = UIDevice.current.model
        let systemVersion = UIDevice.current.systemVersion
        let vendorID = UIDevice.current.identifierForVendor?.uuidString ?? "-"

        let trollStore = detectTrollStore()
        let trollFools = detectTrollFools()
        let taskForPid = testTaskForPid()
        let containerWrite = testContainerWrite()
        let injectionBinaries = testInjectionBinaries()
        // v2.9.155：amfid 推断不再依赖 task_for_pid——注入是静态方式
        // （insert_dylib 改 Mach-O 加载命令 + ct_bypass 重签名），TrollStore 非越狱
        // 环境拿不到其他进程端口是常态，task_for_pid 失败不代表注入不可用。
        let amfidBypassInferred = !injectionBinaries.isEmpty && injectionBinaries.values.allSatisfy { $0 } && containerWrite

        // v2.9.153：Entitlements 检测改用 SecTask 直接读自身代码签名（最可靠），
        // 行为测试（bundleWrite/root spawn）只作交叉验证。entitlements 是安装时写入的，
        // 因此反映的是"安装时 TrollStore 开关状态"；开启开关后必须卸载重装才生效。
        let ent = snapshotEntitlements()
        let bundleWriteOK = testBundleWrite()
        let rootDiag = InjectionManager.shared.diagnoseRoot()
        let spawnIsRoot = (rootDiag["is_root"] as? Bool) ?? false
        let entDetail: String
        if ent.noSandbox {
            var parts: [String] = ["已生效（签名含 no-sandbox）"]
            parts.append(ent.summary)
            if bundleWriteOK { parts.append("Bundle 写入实测通过") }
            if spawnIsRoot { parts.append("persona spawn uid=0") }
            entDetail = parts.joined(separator: "\n")
        } else {
            var parts: [String] = ["未检测到 no-sandbox（沙盒未解除）"]
            parts.append(ent.summary)
            if bundleWriteOK { parts.append("Bundle 写入实测通过") }
            if spawnIsRoot { parts.append("persona spawn uid=0") }
            parts.append("注入功能需要在 TrollStore 设置中开启「编辑 Entitlements」，然后卸载重装本 App（覆盖安装不会重新应用权限）。")
            entDetail = parts.joined(separator: "\n")
        }
        let entitlementsOK = ent.noSandbox || bundleWriteOK || spawnIsRoot  // 内部记录用，不影响 ready 和 UI 显示

        var checks: [Check] = []
        // v3.0.2: 去掉 TrollStore 已安装 / Entitlements 权限 / TrollFools 已安装 三个检测（包已是 tipa，检测无意义）
        let tfpDetail: String
        if taskForPid {
            tfpDetail = "实测可获取其他进程端口，进程级操作可用"
        } else if ent.taskForPidAllow {
            // v2.9.156：签名已授予 task_for_pid-allow → 绿勾；实测被拦是 TrollStore
            // 非越狱常态（不影响静态注入），如实写进说明
            tfpDetail = "签名含 task_for_pid-allow；TrollStore 非越狱环境实测进程端口获取被系统拦截，不影响静态注入，进程级内存操作受限"
        } else {
            tfpDetail = "无 task_for_pid-allow，进程级操作受限"
        }
        checks.append(Check(label: "task_for_pid 权限", passed: ent.taskForPidAllow || taskForPid, detail: tfpDetail, infoOnly: false))
        checks.append(Check(label: "App 容器任意读写", passed: containerWrite, detail: containerWrite ? "AppDataContainers 权限生效，可写任意 App 沙盒" : "无法写入其他 App 容器（缺 entitlement）", infoOnly: false))
        for (name, ok) in injectionBinaries.sorted(by: { $0.key < $1.key }) {
            checks.append(Check(label: "注入二进制 \(name)", passed: ok, detail: ok ? "已捆绑且可执行" : "缺失或不可执行", infoOnly: false))
        }
        checks.append(Check(label: "amfid 绕过（推断）", passed: amfidBypassInferred, detail: amfidBypassInferred ? "ct_bypass 重签名 + 注入工具 + 容器读写 均就绪，dylib 注入链路可工作" : "条件不足，unsigned dylib 可能无法加载", infoOnly: false))

        // v2.9.156：ready 不再依赖 taskForPid——静态注入（insert_dylib+ct_bypass 重签名）
        // 与进程端口无关；TrollStore 非越狱拿不到其他进程端口是常态，不应导致"环境异常"
        let ready = trollStore && amfidBypassInferred

        // v2.9.67：收集增强设备信息
        let modelIdentifier = Self.deviceModelIdentifier()
        let modelName = Self.deviceModelName(identifier: modelIdentifier)
        let storage = Self.storageInfo()
        let memoryTotal = Self.memoryTotal()
        let screenSize = "\(Int(UIScreen.main.bounds.width))×\(Int(UIScreen.main.bounds.height))"
        let appCount = AppCatalog.list().count
        let workspaceSize = Self.workspaceSize()
        let batteryLevel = UIDevice.current.isBatteryMonitoringEnabled ? "\(Int(UIDevice.current.batteryLevel * 100))%" : "未知"
        if !UIDevice.current.isBatteryMonitoringEnabled { UIDevice.current.isBatteryMonitoringEnabled = true }

        let report = Report(
            deviceName: deviceName, model: model, systemVersion: systemVersion, vendorID: vendorID,
            trollStore: trollStore, trollFools: trollFools, taskForPid: taskForPid,
            containerWrite: containerWrite, injectionBinaries: injectionBinaries,
            amfidBypassInferred: amfidBypassInferred, entitlementsOK: entitlementsOK,
            rootDiagnosis: rootDiag, checks: checks, ready: ready,
            deviceModelIdentifier: modelIdentifier, deviceModelName: modelName,
            storageTotal: storage.total, storageFree: storage.free,
            memoryTotal: memoryTotal, screenSize: screenSize,
            appCount: appCount, workspaceSize: workspaceSize,
            batteryLevel: batteryLevel
        )
        // v2.9.144：@Published 后台线程赋值会触发 SwiftUI 崩溃，挪主线程回写
        if Thread.isMainThread {
            lastReport = report
            AuditLog.shared.log("device.probe", detail: "ready=\(ready) trollStore=\(trollStore) entsOK=\(entitlementsOK) tfpid=\(taskForPid) container=\(containerWrite)")
        } else {
            DispatchQueue.main.async {
                self.lastReport = report
                AuditLog.shared.log("device.probe", detail: "ready=\(ready) trollStore=\(trollStore) entsOK=\(entitlementsOK) tfpid=\(taskForPid) container=\(containerWrite)")
            }
        }
        return report
    }

    // MARK: 检测实现

    private func detectTrollStore() -> Bool {
        if getenv("TROLLSTORE") != nil { return true }
        if FileManager.default.fileExists(atPath: "/.TrollStore") { return true }
        if FileManager.default.fileExists(atPath: "/var/jb") { return true }
        if FileManager.default.fileExists(atPath: "/private/preboot/jb") { return true }
        if AppCatalog.list().contains(where: { $0.bundleId == "com.opa334.TrollStore" }) { return true }
        // v2.9.159：AppCatalog 兜底——直接扫容器目录找 TrollStore.app（不依赖枚举结果）
        for root in ["/var/containers/Bundle/Application", "/private/var/containers/Bundle/Application"] {
            if let dirs = try? FileManager.default.contentsOfDirectory(atPath: root),
               dirs.contains(where: { $0.localizedCaseInsensitiveContains("TrollStore") }) {
                return true
            }
        }
        return false
    }

    private func detectTrollFools() -> Bool {
        // 已知 bundle id 全集（含源码常量 wiki.qaq.TrollFools —— 官方 release 真实 identifier）
        let ids = [
            "wiki.qaq.TrollFools",
            "com.iomsec.TrollFools",
            "com.icraze.TrollFools",
            "com.statelasso.TrollFools",
            "com.opa334.TrollFools",
        ]
        let apps = AppCatalog.list()
        if apps.contains(where: { ids.contains($0.bundleId) }) { return true }
        // 兜底：按名字/路径模糊匹配（TrollFools / TrollFools.app）
        if apps.contains(where: {
            $0.bundleId.localizedCaseInsensitiveContains("trollfools") ||
            $0.name.localizedCaseInsensitiveContains("trollfools") ||
            $0.path.localizedCaseInsensitiveContains("TrollFools.app")
        }) { return true }
        // v2.9.159：AppCatalog 兜底——直接扫容器目录找 TrollFools.app（不依赖枚举结果）
        for root in ["/var/containers/Bundle/Application", "/private/var/containers/Bundle/Application"] {
            if let dirs = try? FileManager.default.contentsOfDirectory(atPath: root),
               dirs.contains(where: { $0.localizedCaseInsensitiveContains("TrollFools") }) {
                return true
            }
        }
        return false
    }

    // v2.9.154：真实测 task_for_pid-allow。
    // 153 用 pid=1(launchd)——但 TrollStore 是非越狱环境，拿特权进程端口会被系统拒绝
    // （用户反馈"amfid 不生效"）。注入实际场景是拿"普通 App 进程"端口，
    // 因此 spawn 一个用户级子进程(/usr/bin/true)来实测——与注入任意 App 完全等价。
    private func testTaskForPid() -> Bool {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        let sr = posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, nil)
        guard sr == 0 else { return false }
        var task: UInt32 = 0
        let kr = tm_task_for_pid(tm_mach_task_self(), pid, &task)
        if kr == 0 {
            _ = tm_mach_port_deallocate(tm_mach_task_self(), task)
        }
        kill(pid, SIGKILL)
        waitpid(pid, nil, 0)
        return kr == 0
    }

    // v2.9.153b：SecTask 是私有 API（公共 SDK 不导出），用 @_silgen_name 直接声明符号
    @_silgen_name("SecTaskCreateFromSelf")
    private func secTaskCreateFromSelf(_ allocator: CFAllocator?) -> CFTypeRef?

    @_silgen_name("SecTaskCopyValueForEntitlement")
    private func secTaskCopyValueForEntitlement(_ task: CFTypeRef, _ entitlement: CFString, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    /// v2.9.153：读取本进程代码签名里的 entitlements（最可靠——直接读签名，不靠行为推断）
    private func readOwnEntitlement(_ key: String) -> Bool {
        guard let task = secTaskCreateFromSelf(nil) else { return false }
        guard let v = secTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(v as! CFBoolean)
    }

    /// 一次性读全关键 entitlements（返回是否 no-sandbox 等）
    struct EntitlementSnapshot {
        let noSandbox: Bool
        let platformApplication: Bool
        let taskForPidAllow: Bool
        let getTaskAllow: Bool
        let summary: String
    }

    private func snapshotEntitlements() -> EntitlementSnapshot {
        let ns = readOwnEntitlement("com.apple.private.security.no-sandbox")
        let pa = readOwnEntitlement("platform-application")
        let tf = readOwnEntitlement("task_for_pid-allow")
        let gt = readOwnEntitlement("get-task-allow")
        var parts: [String] = []
        parts.append("no-sandbox: \(ns ? "有" : "无")")
        parts.append("platform-app: \(pa ? "有" : "无")")
        parts.append("task_for_pid: \(tf ? "有" : "无")")
        parts.append("get-task-allow: \(gt ? "有" : "无")")
        return EntitlementSnapshot(
            noSandbox: ns, platformApplication: pa,
            taskForPidAllow: tf, getTaskAllow: gt,
            summary: parts.joined(separator: " · ")
        )
    }

    private func testContainerWrite() -> Bool {
        guard let other = AppCatalog.list().first(where: { $0.bundleId != Bundle.main.bundleIdentifier }),
              let container = other.containerPath else { return false }
        let probe = URL(fileURLWithPath: container).appendingPathComponent(".trollmcp_probe_\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    // v2.9.65：实际写其他 App Bundle 目录检测 root 权限。
    // Bundle 目录（/private/var/containers/Bundle/Application/...）只有 root 能写，
    // 能写就证明 persona spawn + no-sandbox + container-manager 等 entitlements 完整生效。
    // 这是注入操作的真正前提，比执行外部命令更可靠。
    private func testBundleWrite() -> Bool {
        let apps = AppCatalog.list()
        // 优先选系统 App（bundle 路径稳定，不会因用户操作而变化），但系统 App 可能不可写
        // 选第一个非自身的 App 即可
        guard let other = apps.first(where: { $0.bundleId != Bundle.main.bundleIdentifier && !$0.path.isEmpty }) else { return false }
        let probe = URL(fileURLWithPath: other.path).appendingPathComponent(".trollagent_probe_\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private func testInjectionBinaries() -> [String: Bool] {
        let names = ["ldid", "optool", "insert_dylib", "ct_bypass"]
        var result: [String: Bool] = [:]
        for name in names {
            guard let path = InjectionManager.shared.binaryPath(name) else {
                result[name] = false
                continue
            }
            // 真实可执行性：access(X_OK) 通过且文件存在
            result[name] = access(path, X_OK) == 0
        }
        return result
    }

    // MARK: v2.9.67 增强设备信息辅助方法

    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }

    static func deviceModelName(identifier: String) -> String {
        let map: [String: String] = [
            "iPhone1,1": "iPhone", "iPhone1,2": "iPhone 3G", "iPhone2,1": "iPhone 3GS",
            "iPhone3,1": "iPhone 4", "iPhone3,2": "iPhone 4", "iPhone3,3": "iPhone 4",
            "iPhone4,1": "iPhone 4S", "iPhone5,1": "iPhone 5", "iPhone5,2": "iPhone 5",
            "iPhone5,3": "iPhone 5c", "iPhone5,4": "iPhone 5c",
            "iPhone6,1": "iPhone 5s", "iPhone6,2": "iPhone 5s",
            "iPhone7,1": "iPhone 6 Plus", "iPhone7,2": "iPhone 6",
            "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
            "iPhone9,1": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,3": "iPhone 7", "iPhone9,4": "iPhone 7 Plus",
            "iPhone10,1": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,3": "iPhone X",
            "iPhone10,4": "iPhone 8", "iPhone10,5": "iPhone 8 Plus", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPad1,1": "iPad", "iPad2,1": "iPad 2", "iPad2,2": "iPad 2", "iPad2,3": "iPad 2", "iPad2,4": "iPad 2",
            "iPad3,1": "iPad (3rd)", "iPad3,2": "iPad (3rd)", "iPad3,3": "iPad (3rd)",
            "iPad3,4": "iPad (4th)", "iPad3,5": "iPad (4th)", "iPad3,6": "iPad (4th)",
            "iPad4,1": "iPad Air", "iPad4,2": "iPad Air", "iPad4,3": "iPad Air",
            "iPad5,3": "iPad Air 2", "iPad5,4": "iPad Air 2",
            "iPad6,7": "iPad Pro (12.9\")", "iPad6,8": "iPad Pro (12.9\")",
            "iPad6,3": "iPad Pro (9.7\")", "iPad6,4": "iPad Pro (9.7\")",
            "iPad7,1": "iPad Pro (12.9\") 2nd", "iPad7,2": "iPad Pro (12.9\") 2nd",
            "iPad7,3": "iPad Pro (10.5\")", "iPad7,4": "iPad Pro (10.5\")",
            "iPad7,5": "iPad (6th)", "iPad7,6": "iPad (6th)",
            "iPad8,1": "iPad Pro (11\")", "iPad8,2": "iPad Pro (11\")", "iPad8,3": "iPad Pro (11\")", "iPad8,4": "iPad Pro (11\")",
            "iPad8,5": "iPad Pro (12.9\") 3rd", "iPad8,6": "iPad Pro (12.9\") 3rd", "iPad8,7": "iPad Pro (12.9\") 3rd", "iPad8,8": "iPad Pro (12.9\") 3rd",
            "iPad11,1": "iPad mini (5th)", "iPad11,2": "iPad mini (5th)",
            "iPad11,3": "iPad Air (3rd)", "iPad11,4": "iPad Air (3rd)",
            "iPad11,6": "iPad (8th)", "iPad11,7": "iPad (8th)",
            "iPad12,1": "iPad (9th)", "iPad12,2": "iPad (9th)",
            "iPad13,1": "iPad Air (4th)", "iPad13,2": "iPad Air (4th)",
            "iPad13,4": "iPad Pro (11\") 3rd", "iPad13,5": "iPad Pro (11\") 3rd", "iPad13,6": "iPad Pro (11\") 3rd", "iPad13,7": "iPad Pro (11\") 3rd",
            "iPad13,8": "iPad Pro (12.9\") 5th", "iPad13,9": "iPad Pro (12.9\") 5th", "iPad13,10": "iPad Pro (12.9\") 5th", "iPad13,11": "iPad Pro (12.9\") 5th",
            "iPad14,1": "iPad mini (6th)", "iPad14,2": "iPad mini (6th)",
            "iPod1,1": "iPod touch", "iPod2,1": "iPod touch (2nd)", "iPod3,1": "iPod touch (3rd)",
            "iPod4,1": "iPod touch (4th)", "iPod5,1": "iPod touch (5th)", "iPod7,1": "iPod touch (6th)", "iPod9,1": "iPod touch (7th)"
        ]
        return map[identifier] ?? identifier
    }

    static func storageInfo() -> (total: String, free: String) {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let total = attrs[.systemSize] as? Int64,
               let free = attrs[.systemFreeSize] as? Int64 {
                return (formatBytes(total), formatBytes(free))
            }
        } catch {}
        return ("未知", "未知")
    }

    static func memoryTotal() -> String {
        let total = ProcessInfo.processInfo.physicalMemory
        return formatBytes(Int64(total))
    }

    static func workspaceSize() -> String {
        let workspacePath = NSHomeDirectory().appending("/Documents/Workspace")
        guard let enumerator = FileManager.default.enumerator(atPath: workspacePath) else { return "0 B" }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (workspacePath as NSString).appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return formatBytes(total)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }
}
