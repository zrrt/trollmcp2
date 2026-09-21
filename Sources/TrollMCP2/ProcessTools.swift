import Foundation

// v2.9.184：libproc 进程枚举（proc_listallpids / proc_pidpath，纯 C API，
// 不依赖 shell/ps/task_for_pid——TrollStore 无 shell 环境 /bin/ps 不可用，
// 导致 app.status / app.decrypt 的进程检测永远 false（实测证实）。
// Darwin 模块不暴露 libproc 符号，用 @_silgen_name 直接绑定系统符号（iOS 6+ 均存在）。

// v2.9.70：进程管理 + 测试编排器
// 1. 进程管理 — 目标 App 启停、重启、前台状态、CPU/内存/线程采样
// 2. 测试编排器 — 注入→启动→采集→验证→报告，一键闭环

// MARK: - 进程管理工具

final class AppStartTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.start",
        summary: "Launch an app. Multi-strategy: open -b -> registry path direct exec -> URL scheme, each level logs real errors/stderr.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "wait_seconds": "Wait seconds after launch (default 3, to confirm alive)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let wait = max((params["wait_seconds"] as? Int) ?? 3, 1)
        let start = Date()
        var errors: [[String: Any]] = []
        func find() -> Int32 { findPid(by: bundleId) }

        // 方法 1：open -b（正确带 -b 标志；旧版漏了 -b 导致 exit 2 误报 Bundle ID 错误）
        let (c1, o1) = InjectionManager.shared.spawnRoot("/usr/bin/open", args: ["-b", bundleId])
        Thread.sleep(forTimeInterval: TimeInterval(wait))
        var pid = find()
        if pid > 0 {
            return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "open -b",
                    "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
        }
        errors.append(["step": "open -b", "exit": Int(c1), "stderr": String(o1.prefix(400))])

        // 方法 1.5（v2.9.185）：LSApplicationWorkspace 私有 API 拉起（TrollStore 可用，不依赖 shell）
        if let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
           ws.responds(to: NSSelectorFromString("openApplicationWithBundleID:")) {
            _ = ws.perform(NSSelectorFromString("openApplicationWithBundleID:"), with: bundleId)
            Thread.sleep(forTimeInterval: TimeInterval(wait))
            pid = find()
            if pid > 0 {
                return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "ls_workspace_open",
                        "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
            }
            errors.append(["step": "ls_workspace_open", "exit": 0, "stderr": "openApplicationWithBundleID 未拉起"])
        }

        // 方法 2：注册表路径 → 直接执行主二进制（绕过 open 依赖）
        if let app = AppCatalog.find(bundleId) {
            let plistPath = app.path + "/Info.plist"
            let plist = NSDictionary(contentsOfFile: plistPath)
            let exec = (plist?["CFBundleExecutable"] as? String) ?? ""
            if !app.path.isEmpty, !exec.isEmpty {
                let bin = app.path + "/" + exec
                if FileManager.default.fileExists(atPath: bin) {
                    let (c2, o2) = InjectionManager.shared.spawnRoot(bin, args: [])
                    Thread.sleep(forTimeInterval: TimeInterval(wait))
                    pid = find()
                    if pid > 0 {
                        return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "direct_exec",
                                "executable": bin, "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
                    }
                    errors.append(["step": "direct_exec", "exit": Int(c2), "stderr": String(o2.prefix(400))])
                }
            }
            // 方法 3：URL scheme
            if let types = plist?["CFBundleURLTypes"] as? [[String: Any]],
               let schemes = types.first?["CFBundleURLSchemes"] as? [String],
               let scheme = schemes.first {
                let (c3, o3) = InjectionManager.shared.spawnRoot("/usr/bin/open", args: ["\(scheme)://"])
                Thread.sleep(forTimeInterval: TimeInterval(wait))
                pid = find()
                if pid > 0 {
                    return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "url_scheme",
                            "scheme": scheme, "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
                }
                errors.append(["step": "url_scheme", "exit": Int(c3), "stderr": String(o3.prefix(400))])
            }
        }

        return ["bundle_id": bundleId, "started": false, "pid": 0,
                "launch_ms": Int(Date().timeIntervalSince(start) * 1000),
                "errors": errors,
                "next_step": "先查 app.encrypt_info（已加密需 app.decrypt 砸壳）→ app.status 确认进程；反调试拦截时考虑 injection.mem 内存注入",
                "hint": "三种启动方式均失败，见 errors 明细（不再是 Bundle ID 误报）"]
    }
}

final class AppStopTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.stop",
        summary: "Kill (stop) an app process. Returns success and original PID.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }

        let pid = findPid(by: bundleId)
        guard pid > 0 else {
            return ["bundle_id": bundleId, "stopped": false, "reason": "进程未运行"]
        }

        let (exitCode, _) = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(pid)"])
        Thread.sleep(forTimeInterval: 1)
        let stillRunning = findPid(by: bundleId) > 0

        return [
            "bundle_id": bundleId,
            "original_pid": pid,
            "stopped": !stillRunning,
            "kill_exit": exitCode
        ]
    }
}

final class AppRestartTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.restart",
        summary: "Restart/kill then relaunch an app. Use for: restart app after injection, clear app state, force close and reopen. Don't use for: just opening app (use app.launch), uninstall app (use app.uninstall). Example: user says '重启小红书' → restart com.xingin.discover.",
        parameters: [
            "bundle_id": "Target App bundle_id (required). e.g. com.xingin.discover",
            "wait_seconds": "Wait seconds after launch (default 3)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let wait = (params["wait_seconds"] as? Int) ?? 3

        let start = Date()
        // 杀掉旧进程——v2.9.251: spawnRoot 在 TrollStore 无 root shell(/bin/sh not found)下 kill 不执行,
        // App 没真正重启导致 ControlAgent.dylib 不重新加载、4789 服务器起不来;改普通 spawn(用户态可杀自己进程)
        // v2.9.256: 实测 app.restart 返回 old_pid==new_pid（PID 未变=假重启）——
        // 普通 spawn /bin/kill 在 TrollStore 沙盒无 task_for_pid 杀不掉其他 App 进程。
        // 改调 SpringBoardServices 私有 API SBTerminateApplication（platform-application entitlement 可调，
        // iOS 全版本存在），失败再兜底 /bin/kill。
        // v2.9.257: SBTerminateApplication 实测也无效(需 springboard.debug entitlement)。对齐 TrollFools
        // TFUtilKillAll——直接进程内调 kill() 系统调用(platform-application 权限足够),这才是验证过的可靠方式。
        let oldPid = findPid(by: bundleId)
        if oldPid > 0 {
            let killRet = kill(oldPid, SIGKILL)
            if killRet != 0 {
                NSLog("[app.restart] kill(\(oldPid),SIGKILL) errno=\(errno)")
                let terminated = Self.terminateApplication(bundleId: bundleId)
                if !terminated {
                    let (kexit, kout) = InjectionManager.shared.spawn("/bin/kill", args: ["-9", "\(oldPid)"])
                    if kexit != 0 { NSLog("[app.restart] fallback kill pid \(oldPid) exit=\(kexit) \(kout)") }
                }
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
        // 启动——v2.9.251: /usr/bin/open 在 TrollStore 不可靠,改 SBSLaunch(验证可用)
        let (launched, launchMsg) = ProcessHelper.launchApp(bundleId: bundleId)
        if !launched { NSLog("[app.restart] launch failed: \(launchMsg)") }
        Thread.sleep(forTimeInterval: TimeInterval(wait))

        let newPid = findPid(by: bundleId)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        return [
            "bundle_id": bundleId,
            "old_pid": oldPid,
            "new_pid": newPid,
            "restarted": newPid > 0,
            "restart_ms": elapsed
        ]
    }

    /// v2.9.256: 真终止 App——SpringBoardServices 私有 API SBTerminateApplication。
    /// TrollStore 的 App 带 platform-application entitlement，可调该符号终止任意前台 App；
    /// 比 /bin/kill 可靠（kill 需 task_for_pid/root，TrollStore 非越狱下不可用）。
    static func terminateApplication(bundleId: String) -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY) else {
            return false
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SBTerminateApplication") else {
            NSLog("[app.restart] SBTerminateApplication symbol not found")
            return false
        }
        typealias TermFn = @convention(c) (CFString) -> Int32
        let fn = unsafeBitCast(sym, to: TermFn.self)
        let ret = fn(bundleId as CFString)
        if ret != 0 { NSLog("[app.restart] SBTerminateApplication ret=\(ret)") }
        return ret == 0
    }
}

final class AppStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.status",
        summary: "Check app running status: running, PID, foreground/background, CPU%, memory, thread count, uptime.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }

        let pid = findPid(by: bundleId)
        guard pid > 0 else {
            return ["bundle_id": bundleId, "running": false]
        }

        // 用 ps 拿详细信息
        let (_, psOutput) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-p", "\(pid)", "-o", "pid,%cpu,%mem,rss,etime,comm"])
        let lines = psOutput.components(separatedBy: .newlines)
        var cpu = "", mem = "", rss = "", etime = "", comm = ""
        if lines.count >= 2 {
            let parts = lines[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 6 {
                cpu = parts[1]; mem = parts[2]; rss = parts[3]; etime = parts[4]; comm = parts[5]
            }
        }

        // 线程数
        let (_, threadOutput) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-M", "\(pid)"])
        let threadCount = threadOutput.components(separatedBy: .newlines).count - 1

        return [
            "bundle_id": bundleId,
            "running": true,
            "pid": pid,
            "cpu_percent": cpu,
            "memory_percent": mem,
            "rss_kb": rss,
            "elapsed": etime,
            "thread_count": threadCount,
            "process_name": comm
        ]
    }
}

final class AppStatsTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.stats",
        summary: "Sample CPU/memory of an app for N seconds, output avg/peak/trend. For perf analysis and leak detection.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "duration": "Sampling duration in seconds (default 10)",
            "interval": "Sampling interval in seconds (default 1)"
        ],
    verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let duration = (params["duration"] as? Int) ?? 10
        let interval = (params["interval"] as? Int) ?? 1

        var samples: [[String: Any]] = []
        var cpuValues: [Double] = []
        var memValues: [Int] = []

        let pid = findPid(by: bundleId)
        guard pid > 0 else {
            return ["bundle_id": bundleId, "error": "App 未运行"]
        }

        let steps = max(1, duration / interval)
        for i in 0..<steps {
            let (_, output) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-p", "\(pid)", "-o", "%cpu,rss"])
            let lines = output.components(separatedBy: .newlines)
            if lines.count >= 2 {
                let parts = lines[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let cpu = Double(parts[0]) ?? 0
                    let rss = Int(parts[1]) ?? 0
                    cpuValues.append(cpu)
                    memValues.append(rss)
                    samples.append(["t": i * interval, "cpu": cpu, "rss_kb": rss])
                }
            }
            if i < steps - 1 { Thread.sleep(forTimeInterval: TimeInterval(interval)) }
        }

        let avgCpu = cpuValues.isEmpty ? 0 : cpuValues.reduce(0, +) / Double(cpuValues.count)
        let maxCpu = cpuValues.max() ?? 0
        let avgMem = memValues.isEmpty ? 0 : memValues.reduce(0, +) / memValues.count
        let maxMem = memValues.max() ?? 0
        let minMem = memValues.min() ?? 0
        let memGrowth = maxMem - minMem

        return [
            "bundle_id": bundleId,
            "pid": pid,
            "duration_s": duration,
            "samples": samples.count,
            "cpu": ["avg": String(format: "%.1f", avgCpu), "max": String(format: "%.1f", maxCpu), "unit": "%"],
            "memory": ["avg_kb": avgMem, "max_kb": maxMem, "min_kb": minMem, "growth_kb": memGrowth],
            "trend": samples,
            "leak_suspect": memGrowth > 1024 ? "⚠️ 内存增长 \(memGrowth)KB，疑似泄漏" : "内存稳定"
        ]
    }
}

// MARK: - 测试编排器

final class TestRunTool: MCPTool {
    let definition = ToolDefinition(
        name: "test.run",
        summary: "One-click test pipeline: inject dylib -> launch app -> wait stable -> collect logs/perf -> stop -> report.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "dylib_path": "dylib path to inject (optional, skip if empty)",
            "steps": "Steps comma-separated: inject,start,wait,stats,logs,stop,report (default all)",
            "wait_seconds": "Wait seconds after launch (default 5)",
            "stats_duration": "Stats sampling duration (default 10)",
            "report_name": "Report name (default test_report_<timestamp>)"
        ],
    verified: true)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let dylibPath = params["dylib_path"] as? String
        let stepsStr = (params["steps"] as? String) ?? "inject,start,wait,stats,logs,stop,report"
        let wait = (params["wait_seconds"] as? Int) ?? 5
        let statsDuration = (params["stats_duration"] as? Int) ?? 10
        let reportName = (params["report_name"] as? String) ?? "test_report"

        let steps = stepsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var results: [String: Any] = [:]
        var timeline: [[String: Any]] = []
        let runId = UUID().uuidString.prefix(8).description
        let startTime = Date()

        func record(_ step: String, _ data: [String: Any]) {
            results[step] = data
            timeline.append(["step": step, "ts": Int(Date().timeIntervalSince(startTime)), "data": data])
        }

        // 1. 注入
        if steps.contains("inject"), let dylib = dylibPath {
            do {
                let injectResult = try InjectionManager.shared.enable(bundleId: bundleId, dylibName: "@rpath/\(URL(fileURLWithPath: dylib).lastPathComponent)", dylibSourcePath: dylib)
                record("inject", ["success": injectResult["injected"] as? Bool ?? false, "detail": String(describing: injectResult).prefix(500)])
            } catch {
                record("inject", ["success": false, "error": "\(error)"])
            }
        }

        // 2. 启动
        if steps.contains("start") {
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
            Thread.sleep(forTimeInterval: TimeInterval(wait))
            let pid = findPid(by: bundleId)
            record("start", ["pid": pid, "running": pid > 0])
        }

        // 3. 等待稳定（已在 start 中等待）
        if steps.contains("wait") {
            Thread.sleep(forTimeInterval: TimeInterval(wait))
            record("wait", ["seconds": wait])
        }

        // 4. 性能采样
        if steps.contains("stats") {
            let pid = findPid(by: bundleId)
            if pid > 0 {
                var cpuValues: [Double] = []
                var memValues: [Int] = []
                for _ in 0..<statsDuration {
                    let (_, output) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-p", "\(pid)", "-o", "%cpu,rss"])
                    let lines = output.components(separatedBy: .newlines)
                    if lines.count >= 2 {
                        let parts = lines[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if parts.count >= 2 {
                            cpuValues.append(Double(parts[0]) ?? 0)
                            memValues.append(Int(parts[1]) ?? 0)
                        }
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
                let avgCpu = cpuValues.isEmpty ? 0 : cpuValues.reduce(0, +) / Double(cpuValues.count)
                let maxMem = memValues.max() ?? 0
                record("stats", ["cpu_avg": String(format: "%.1f", avgCpu), "mem_max_kb": maxMem, "samples": cpuValues.count])
            } else {
                record("stats", ["error": "进程不存在"])
            }
        }

        // 5. 采集日志
        if steps.contains("logs") {
            let workspace = NSHomeDirectory().appending("/Documents/Workspace/logs")
            try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
            let logPath = workspace.appending("/\(reportName)_\(runId).log")
            let (_, logOutput) = InjectionManager.shared.spawnRoot("/usr/bin/log", args: ["show", "--last", "\(wait + statsDuration + 10)s", "--predicate", "process == '\(bundleId)'"])
            try? logOutput.write(toFile: logPath, atomically: true, encoding: .utf8)
            record("logs", ["path": logPath, "bytes": (try? Data(contentsOf: URL(fileURLWithPath: logPath)).count) ?? 0])
        }

        // 6. 停止
        if steps.contains("stop") {
            let pid = findPid(by: bundleId)
            if pid > 0 {
                let _ = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(pid)"])
            }
            record("stop", ["killed_pid": pid])
        }

        // 7. 生成报告
        if steps.contains("report") {
            let workspace = NSHomeDirectory().appending("/Documents/Workspace/reports")
            try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
            let reportPath = workspace.appending("/\(reportName)_\(runId).json")
            let report: [String: Any] = [
                "run_id": runId,
                "bundle_id": bundleId,
                "dylib": dylibPath ?? "",
                "start_time": ISO8601DateFormatter().string(from: startTime),
                "duration_ms": Int(Date().timeIntervalSince(startTime) * 1000),
                "steps": results,
                "timeline": timeline
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                try? data.write(to: URL(fileURLWithPath: reportPath))
            }
            record("report", ["path": reportPath])
        }

        return [
            "run_id": runId,
            "bundle_id": bundleId,
            "total_ms": Int(Date().timeIntervalSince(startTime) * 1000),
            "steps_executed": steps,
            "results": results,
            "timeline": timeline
        ]
    }
}

// MARK: - 辅助函数

// libproc 系统符号直绑（iOS 6+；macOS CI 交叉编译 iOS target 也可链接）
@_silgen_name("proc_listallpids")
func sys_proc_listallpids(_ buffer: UnsafeMutablePointer<pid_t>?, _ bufferSize: Int32) -> Int32

@_silgen_name("proc_pidpath")
func sys_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ buffersize: UInt32) -> Int32

/// v2.9.184：libproc 枚举进程，按可执行文件路径前缀匹配（xxx.app 目录）。
/// 纯 C API，TrollStore 无 shell 环境可用；非越狱可能受进程可见性限制，实测确认。
func findPidByExecutable(bundlePath: String) -> Int32 {
    var pids = [pid_t](repeating: 0, count: 2048)
    let count = sys_proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return 0 }
    for i in 0..<Int(count) {
        let pid = pids[i]
        var buf = [CChar](repeating: 0, count: 4096)
        let len = sys_proc_pidpath(pid, &buf, UInt32(buf.count))
        if len > 0 {
            let path = String(cString: buf)
            // v2.9.186：排除扩展进程（.appex）——扩展在 bundle 目录内但非主 App 进程，
            // 此前误把 NotificationServiceExtension 当主进程（真机实测 pid 11718 假阳性，
            // 导致 app.start 误报启动成功、app.decrypt 拿扩展进程 task 读镜像表全空）
            if path.contains(".appex") { continue }
            // 可执行文件在 .app 目录内，路径以 bundlePath 开头即命中
            if path.hasPrefix(bundlePath) {
                return pid
            }
        }
    }
    return 0
}

func findPid(by bundleId: String) -> Int32 {
    // v2.9.184：主用 libproc（不依赖 shell）。AppCatalog 拿 bundle 可执行路径。
    if let entry = AppCatalog.find(bundleId) {
        let exePath = entry.path + "/" + entry.execName
        let pid = findPidByExecutable(bundlePath: exePath)
        if pid > 0 { return pid }
        // 某些进程的可执行路径与 LSApplicationProxy 记录不完全一致，
        // 用 .app 目录前缀再试一次
        let pid2 = findPidByExecutable(bundlePath: entry.path)
        if pid2 > 0 { return pid2 }
    }
    // 兜底：旧 ps 方式（无 shell 环境会失败，保留仅作兼容）
    let (_, output) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-ax"])
    for line in output.components(separatedBy: .newlines) {
        if line.contains(bundleId) || line.contains(bundleId.replacingOccurrences(of: ".", with: "")) {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
            if let pidStr = parts.first, let pid = Int32(pidStr) {
                return pid
            }
        }
    }
    return 0
}
