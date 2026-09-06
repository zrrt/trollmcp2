import Foundation
import UIKit

// MARK: - 设备环境自检（"检测手机"核心层）

/// 在 iPhone 上自检运行环境：TrollStore/TrollFools 是否可用、task_for_pid 与
/// App 容器任意读写权限是否生效、内置注入二进制可否执行、amfid 绕过是否推断生效。
final class DeviceProbe: ObservableObject {
    static let shared = DeviceProbe()

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
    }

    @Published var lastReport: Report?

    // MARK: Mach 调用（避免 import mach 类型，直接用 UInt32 别名）

    @_silgen_name("task_for_pid")
    private func tm_task_for_pid(_ task: UInt32, _ pid: Int32, _ target_task: UnsafeMutablePointer<UInt32>) -> Int32

    @_silgen_name("mach_task_self")
    private func tm_mach_task_self() -> UInt32

    @_silgen_name("mach_port_deallocate")
    private func tm_mach_port_deallocate(_ task: UInt32, _ name: UInt32) -> Int32

    // MARK: 公开入口

    func run() -> Report {
        let deviceName = UIDevice.current.name
        let model = UIDevice.current.model
        let systemVersion = UIDevice.current.systemVersion
        let vendorID = UIDevice.current.identifierForVendor?.uuidString ?? "-"

        let trollStore = detectTrollStore()
        let trollFools = detectTrollFools()
        let taskForPid = testTaskForPid()
        let containerWrite = testContainerWrite()
        let injectionBinaries = testInjectionBinaries()
        let amfidBypassInferred = taskForPid && !injectionBinaries.isEmpty && injectionBinaries.values.allSatisfy { $0 } && containerWrite

        // v2.9.66：Entitlements 检测改为信息提醒，不打 ✔/✘。
        // 原因：persona spawn / Bundle 写入检测在不同 iOS 版本、不同 TrollStore 配置下表现不一致，
        // 反复误报"未生效"。改为只显示当前检测到的状态和操作建议，不影响整体就绪判断。
        let bundleWriteOK = testBundleWrite()
        let rootDiag = InjectionManager.shared.diagnoseRoot()
        let spawnIsRoot = (rootDiag["is_root"] as? Bool) ?? false
        let entDetail: String
        if bundleWriteOK || spawnIsRoot {
            var parts: [String] = ["已检测到 root 写入能力，注入环境就绪"]
            if bundleWriteOK { parts.append("（Bundle 写入测试通过）") }
            if spawnIsRoot { parts.append("（persona spawn uid=0）") }
            entDetail = parts.joined()
        } else {
            entDetail = "⚠️ 注入功能需要在 TrollStore 中开启「编辑 Entitlements」权限，然后卸载重装本 App（覆盖安装不会重新应用权限）。当前未验证到 root 写入能力，注入可能失败。"
        }
        let entitlementsOK = bundleWriteOK || spawnIsRoot  // 内部记录用，不影响 ready 和 UI 显示

        var checks: [Check] = []
        checks.append(Check(label: "TrollStore 已安装", passed: trollStore, detail: trollStore ? "检测到 TrollStore App 或越狱根" : "未检测到 TrollStore / 越狱环境", infoOnly: false))
        checks.append(Check(label: "TrollStore Entitlements 权限", passed: true, detail: entDetail, infoOnly: true))
        checks.append(Check(label: "TrollFools 已安装", passed: trollFools, detail: trollFools ? "检测到 TrollFools（可注入）" : "未检测到 TrollFools，注入需手动", infoOnly: false))
        checks.append(Check(label: "task_for_pid 权限", passed: taskForPid, detail: taskForPid ? "持有 task_for_pid-allow，可获取进程端口" : "无 task_for_pid-allow，进程级操作受限", infoOnly: false))
        checks.append(Check(label: "App 容器任意读写", passed: containerWrite, detail: containerWrite ? "AppDataContainers 权限生效，可写任意 App 沙盒" : "无法写入其他 App 容器（缺 entitlement）", infoOnly: false))
        for (name, ok) in injectionBinaries.sorted(by: { $0.key < $1.key }) {
            checks.append(Check(label: "注入二进制 \(name)", passed: ok, detail: ok ? "已捆绑且可执行" : "缺失或不可执行", infoOnly: false))
        }
        checks.append(Check(label: "amfid 绕过（推断）", passed: amfidBypassInferred, detail: amfidBypassInferred ? "task_for_pid + 注入工具 + 容器读写 均通过，dylib 注入链路可工作" : "条件不足，unsigned dylib 可能无法加载", infoOnly: false))

        // v2.9.66：ready 不再依赖 entitlementsOK（已改为信息提醒项）
        let ready = trollStore && taskForPid && containerWrite && !injectionBinaries.isEmpty && injectionBinaries.values.allSatisfy { $0 }

        let report = Report(
            deviceName: deviceName, model: model, systemVersion: systemVersion, vendorID: vendorID,
            trollStore: trollStore, trollFools: trollFools, taskForPid: taskForPid,
            containerWrite: containerWrite, injectionBinaries: injectionBinaries,
            amfidBypassInferred: amfidBypassInferred, entitlementsOK: entitlementsOK,
            rootDiagnosis: rootDiag, checks: checks, ready: ready
        )
        lastReport = report
        AuditLog.shared.log("device.probe", detail: "ready=\(ready) trollStore=\(trollStore) entsOK=\(entitlementsOK) tfpid=\(taskForPid) container=\(containerWrite)")
        return report
    }

    // MARK: 检测实现

    private func detectTrollStore() -> Bool {
        if getenv("TROLLSTORE") != nil { return true }
        if FileManager.default.fileExists(atPath: "/.TrollStore") { return true }
        if FileManager.default.fileExists(atPath: "/var/jb") { return true }
        if FileManager.default.fileExists(atPath: "/private/preboot/jb") { return true }
        return AppCatalog.list().contains { $0.bundleId == "com.opa334.TrollStore" }
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
        return apps.contains {
            $0.bundleId.localizedCaseInsensitiveContains("trollfools") ||
            $0.name.localizedCaseInsensitiveContains("trollfools") ||
            $0.path.localizedCaseInsensitiveContains("TrollFools.app")
        }
    }

    private func testTaskForPid() -> Bool {
        var task: UInt32 = 0
        let kr = tm_task_for_pid(tm_mach_task_self(), getpid(), &task)
        if kr == 0 {
            tm_mach_port_deallocate(tm_mach_task_self(), task)
            return true
        }
        return false
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
}
