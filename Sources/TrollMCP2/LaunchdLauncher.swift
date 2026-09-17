import Foundation
import XPC
import Darwin

// v2.9.202：launchd 启动器（复刻 TrollDecrypt 的 td_launchProcess）
// 机制：不经过 SpringBoard/open -b，直接用 _launch_job_routine(OSLaunchdJobSelectorSubmitAndStart)
//      向 launchd 提交 job 启动目标可执行文件 → 进程由 launchd 托管（launchd job 身份）
//      → 跨进程 task_info(TASK_DYLD_INFO) 才能读到 dyld 镜像表（普通前台 App 恒 kr=4）
// 符号：_launch_job_routine / _CFXPCCreateXPCObjectFromCFObject 均为私有，运行时 dlsym 动态获取
enum LaunchdLauncher {
    typealias LaunchJobFn = @convention(c) (Int32, xpc_object_t?, UnsafeMutablePointer<xpc_object_t?>) -> Int32
    typealias CFXPCFn = @convention(c) (CFDictionary?) -> xpc_object_t?

    static let kOSLaunchdJobSelectorSubmitAndStart: Int32 = 1000

    /// 向 launchd 提交并启动目标可执行文件
    /// - Returns: (pid, kr)；pid==-1 表示失败
    static func launch(bundleId: String, executablePath: String, label: String) -> (pid: Int32, kr: Int32) {
        let rtlDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let fn = dlsym(rtlDefault, "_launch_job_routine") else { return (-1, -1) }
        guard let cfFn = dlsym(rtlDefault, "_CFXPCCreateXPCObjectFromCFObject") else { return (-1, -2) }
        let launchJob = unsafeBitCast(fn, to: LaunchJobFn.self)
        let cfxpc = unsafeBitCast(cfFn, to: CFXPCFn.self)

        let plist: [String: Any] = [
            "UserName": "mobile",
            "CFBundleIdentifier": bundleId,
            "_ManagedBy": "com.apple.runningboard",
            "Label": label,
            "ProgramArguments": [executablePath],
            "Program": executablePath,
        ]
        guard let request = cfxpc(plist as CFDictionary) else { return (-1, -3) }
        xpc_dictionary_set_uint64(request, "handle", 0)
        xpc_dictionary_set_uint64(request, "type", 7)

        var response: xpc_object_t?
        let kr = launchJob(kOSLaunchdJobSelectorSubmitAndStart, request, &response)
        guard kr == 0, let resp = response else { return (-1, kr) }
        let pid = xpc_dictionary_get_int64(resp, "pid")
        return (Int32(pid), kr)
    }

    /// 从进程列表找 bundleId 对应 pid（task_for_pid 前置）
    static func findPID(bundleId: String, knownPath: String?) -> Int32? {
        if let knownPath = knownPath {
            // 走 launchd CopyJobWithPID 反查? 简化：直接返回已知 pid（调用方传入）
            _ = knownPath
        }
        return nil
    }
}
