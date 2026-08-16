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

        var checks: [Check] = []
        checks.append(Check(label: "TrollStore 已安装", passed: trollStore,
            detail: trollStore ? "检测到 TrollStore App 或越狱根" : "未检测到 TrollStore / 越狱环境"))
        checks.append(Check(label: "TrollFools 已安装", passed: trollFools,
            detail: trollFools ? "检测到 TrollFools（可注入）" : "未检测到 TrollFools，注入需手动"))
        checks.append(Check(label: "task_for_pid 权限", passed: taskForPid,
            detail: taskForPid ? "持有 task_for_pid-allow，可获取进程端口" : "无 task_for_pid-allow，进程级操作受限"))
        checks.append(Check(label: "App 容器任意读写", passed: containerWrite,
            detail: containerWrite ? "AppDataContainers 权限生效，可写任意 App 沙盒" : "无法写入其他 App 容器（缺 entitlement）"))
        for (name, ok) in injectionBinaries.sorted(by: { $0.key < $1.key }) {
            checks.append(Check(label: "注入二进制 \(name)", passed: ok,
                detail: ok ? "已捆绑且可执行" : "缺失或不可执行"))
        }
        checks.append(Check(label: "amfid 绕过（推断）", passed: amfidBypassInferred,
            detail: amfidBypassInferred ? "task_for_pid + 注入工具 + 容器读写 均通过，dylib 注入链路可工作" : "条件不足，unsigned dylib 可能无法加载"))

        let ready = trollStore && taskForPid && containerWrite && !injectionBinaries.isEmpty && injectionBinaries.values.allSatisfy { $0 }

        let report = Report(
            deviceName: deviceName, model: model, systemVersion: systemVersion, vendorID: vendorID,
            trollStore: trollStore, trollFools: trollFools, taskForPid: taskForPid,
            containerWrite: containerWrite, injectionBinaries: injectionBinaries,
            amfidBypassInferred: amfidBypassInferred, checks: checks, ready: ready
        )
        lastReport = report
        AuditLog.shared.log("device.probe", detail: "ready=\(ready) trollStore=\(trollStore) tfpid=\(taskForPid) container=\(containerWrite)")
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
        let ids = ["com.iomsec.TrollFools", "com.icraze.TrollFools", "com.statelasso.TrollFools", "com.opa334.TrollFools"]
        return AppCatalog.list().contains { ids.contains($0.bundleId) }
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
