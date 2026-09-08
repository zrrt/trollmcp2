import Foundation

// v2.9.70：进程管理 + 测试编排器
// 1. 进程管理 — 目标 App 启停、重启、前台状态、CPU/内存/线程采样
// 2. 测试编排器 — 注入→启动→采集→验证→报告，一键闭环

// MARK: - 进程管理工具

final class AppStartTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.start",
        summary: "启动指定 App。多级策略：open -b → 注册表路径直接执行主二进制 → URL scheme，每级记录真实错误与 stderr，不再误导归因于 Bundle ID。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "wait_seconds": "启动后等待秒数（默认 3，用于确认进程存活）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let wait = max((params["wait_seconds"] as? Int) ?? 3, 1)
        let start = Date()
        var errors: [[String: Any]] = []
        func find() -> Int { findPid(by: bundleId) }

        // 方法 1：open -b（正确带 -b 标志；旧版漏了 -b 导致 exit 2 误报 Bundle ID 错误）
        let (c1, o1) = InjectionManager.shared.spawnRoot("/usr/bin/open", args: ["-b", bundleId])
        Thread.sleep(forTimeInterval: TimeInterval(wait))
        var pid = find()
        if pid > 0 {
            return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "open -b",
                    "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
        }
        errors.append(["step": "open -b", "exit": Int(c1), "stderr": String(o1.prefix(400))])

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
        summary: "停止（杀掉）指定 App 进程。返回是否成功、原 PID。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）"
        ]
    )

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
        summary: "重启指定 App（先杀后启）。返回新 PID、重启耗时。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "wait_seconds": "启动后等待秒数（默认 3）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let wait = (params["wait_seconds"] as? Int) ?? 3

        let start = Date()
        // 杀掉旧进程
        let oldPid = findPid(by: bundleId)
        if oldPid > 0 {
            let _ = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(oldPid)"])
            Thread.sleep(forTimeInterval: 1)
        }
        // 启动
        let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
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
}

final class AppStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.status",
        summary: "查看指定 App 的运行状态：是否运行、PID、前台/后台、CPU 占用、内存占用、线程数、运行时长。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）"
        ]
    )

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
        summary: "对指定 App 进行 CPU/内存采样（持续 N 秒），输出平均值、峰值、趋势。用于性能分析和泄漏检测。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "duration": "采样时长秒数（默认 10）",
            "interval": "采样间隔秒数（默认 1）"
        ]
    )

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
        summary: "一键测试编排：注入 dylib → 启动 App → 等待稳定 → 采集日志/性能 → 停止 → 生成报告。把整个测试闭环自动化，返回每一步的结果和最终报告。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "dylib_path": "要注入的 dylib 路径（可选，不填则跳过注入）",
            "steps": "要执行的步骤，逗号分隔：inject,start,wait,stats,logs,stop,report（默认全部）",
            "wait_seconds": "启动后等待稳定秒数（默认 5）",
            "stats_duration": "性能采样时长（默认 10）",
            "report_name": "报告名称（默认 test_report_时间戳）"
        ]
    )

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

func findPid(by bundleId: String) -> Int32 {
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
