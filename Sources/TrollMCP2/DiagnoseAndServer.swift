import Foundation

// v2.9.71：自动诊断 + 本地 HTTP 服务
// 1. 自动诊断 — 启动失败/崩溃/注入失败自动判因，给出修复建议
// 2. 本地 HTTP 服务 — localhost REST API，其他脚本/工具可调用

// MARK: - 自动诊断工具

final class DiagnoseStartupTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose.startup",
        summary: "Auto-diagnose why an app won't launch. Use for: app crashes on start, won't open, find out why. Don't use for: read crash logs (use fs.crash), inject dylib (use injection.enable). Example: user says '小红书一打开就闪退' → diagnose startup failure.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "auto_fix": "Auto try to fix (default false, just diagnose)"
        ],
        verified: true, category: "diagnose")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let autoFix = (params["auto_fix"] as? Bool) ?? false

        var diagnosis: [String: Any] = ["bundle_id": bundleId]
        var causes: [String] = []
        var fixes: [String] = []

        // 1. 检查 App 是否存在
        let apps = AppCatalog.list()
        guard let target = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["error": "App 未安装: \(bundleId)", "fix": "用 TrollStore 重新安装"]
        }
        diagnosis["app_path"] = target.path

        // 2. 检查主二进制
        let exec = (NSDictionary(contentsOfFile: target.path.appending("/Info.plist"))?["CFBundleExecutable"] as? String) ?? ""
        let binaryPath = target.path.appending("/\(exec)")
        diagnosis["binary_exists"] = FileManager.default.fileExists(atPath: binaryPath)
        if !FileManager.default.fileExists(atPath: binaryPath) {
            causes.append("主二进制不存在")
            fixes.append("重新安装 App")
        }

        // 3. 检查架构（v2.9.125：arch unknown = 解析失败（可能加密），不误判"非 arm64"）
        let (_, fileOutput) = InjectionManager.shared.spawnRoot("/usr/bin/file", args: [binaryPath])
        let isArm64 = fileOutput.contains("arm64")
        let isOtherArch = fileOutput.contains("x86_64") || fileOutput.contains("armv7") || fileOutput.contains("i386")
        if isArm64 {
            diagnosis["arch"] = "arm64"
        } else if isOtherArch {
            diagnosis["arch"] = "非arm64"
        } else {
            diagnosis["arch"] = "unknown"
            diagnosis["arch_note"] = "解析失败（可能加密或特殊 Mach-O），不代表不可启动/不可注入；配合 cryptid 判断"
        }
        if isOtherArch {
            causes.append("非 arm64 架构")
            fixes.append("确认 IPA 是 arm64 构建")
        }

        // 4. 检查签名
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        if !ldidPath.isEmpty {
            let (_, entOutput) = InjectionManager.shared.spawnRoot(ldidPath, args: ["-e", binaryPath])
            diagnosis["signed"] = !entOutput.isEmpty
            if entOutput.isEmpty {
                causes.append("二进制未签名")
                fixes.append("用 ldid 重新签名或用 TrollStore 重装")
            }
        }

        // 5. 检查注入状态和备份
        let backupPath = binaryPath.appending(".bak_macho")
        diagnosis["has_backup"] = FileManager.default.fileExists(atPath: backupPath)
        let frameworksDir = target.path.appending("/Frameworks")
        if let dylibs = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            diagnosis["injected_dylibs"] = dylibs.filter { $0.hasSuffix(".dylib") }
        }

        // 6. 检查最近崩溃日志
        let crashDir = NSHomeDirectory().appending("/Library/Logs/CrashReporter")
        var recentCrash: String?
        if let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) {
            let relevant = files.filter { $0.contains(bundleId) || $0.contains(exec) }
            if let latest = relevant.sorted().last {
                recentCrash = crashDir.appending("/\(latest)")
                diagnosis["recent_crash"] = latest
                // 读取崩溃原因
                if let content = try? String(contentsOfFile: recentCrash!) {
                    let lines = content.components(separatedBy: .newlines)
                    for line in lines.prefix(30) {
                        if line.contains("Exception Type") || line.contains("Termination Reason") || line.contains("dyld") || line.contains("code signature") {
                            causes.append("崩溃: \(line.trimmingCharacters(in: .whitespaces))")
                        }
                    }
                }
            }
        }

        // 7. 尝试启动并观察
        let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
        Thread.sleep(forTimeInterval: 3)
        let pid = findPid(by: bundleId)
        diagnosis["launch_pid"] = pid
        diagnosis["launched"] = pid > 0
        if pid == 0 {
            causes.append("启动后 3 秒内进程消失（闪退）")
            fixes.append("检查崩溃日志中的 dyld 错误，通常是注入的 dylib 依赖缺失")
        }

        // 8. 自动修复
        if autoFix && !causes.isEmpty {
            // 如果有备份且注入了 dylib，尝试恢复备份
            if FileManager.default.fileExists(atPath: backupPath) {
                let _ = InjectionManager.shared.spawnRoot("/bin/cp", args: [backupPath, binaryPath])
                fixes.append("已恢复主二进制备份")
            }
        }

        diagnosis["causes"] = causes
        diagnosis["fixes"] = fixes
        diagnosis["verdict"] = causes.isEmpty ? "✅ 启动正常" : "❌ 发现 \(causes.count) 个问题"
        // v2.9.125：CLI 式一句话结论
        diagnosis["message"] = causes.isEmpty
            ? "未发现启动问题（arch=\(diagnosis["arch"] ?? "unknown")）"
            : "发现 \(causes.count) 个问题：\(causes.prefix(3).joined(separator: "；"))"

        return diagnosis
    }
}

final class DiagnoseCrashTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose.crash",
        summary: "Analyze app crash logs to find root cause. Use for: app keeps crashing, find out why. Don't use for: read raw crash log (use fs.crash), diagnose startup failure (use diagnose.startup). Example: user says '小红书老闪退，什么原因' → analyze crash.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "count": "How many recent crashes to analyze (default 1)"
        ],
    verified: true, category: "diagnose")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let count = (params["count"] as? Int) ?? 1

        let crashDir = NSHomeDirectory().appending("/Library/Logs/CrashReporter")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) else {
            return ["error": "无法访问崩溃日志目录"]
        }

        let relevant = files.filter { $0.contains(bundleId) }.sorted().suffix(count)
        guard !relevant.isEmpty else {
            return ["bundle_id": bundleId, "result": "未找到崩溃日志"]
        }

        var analyses: [[String: Any]] = []
        for file in relevant {
            let path = crashDir.appending("/\(file)")
            guard let content = try? String(contentsOfFile: path) else { continue }

            var analysis: [String: Any] = ["file": file]
            let lines = content.components(separatedBy: .newlines)

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Exception Type:") {
                    analysis["exception_type"] = trimmed.replacingOccurrences(of: "Exception Type: ", with: "")
                } else if trimmed.hasPrefix("Exception Subtype:") {
                    analysis["exception_subtype"] = trimmed.replacingOccurrences(of: "Exception Subtype: ", with: "")
                } else if trimmed.hasPrefix("Termination Reason:") {
                    analysis["termination_reason"] = trimmed.replacingOccurrences(of: "Termination Reason: ", with: "")
                } else if trimmed.hasPrefix("Triggered by Thread:") {
                    analysis["crashed_thread"] = trimmed.replacingOccurrences(of: "Triggered by Thread: ", with: "")
                } else if trimmed.contains("dyld") && (trimmed.contains("error") || trimmed.contains("missing") || trimmed.contains("symbol")) {
                    analysis["dyld_error"] = trimmed
                } else if trimmed.contains("code signature") || trimmed.contains("invalid") {
                    analysis["signature_issue"] = trimmed
                }
            }

            // 提取崩溃线程调用栈（前 10 帧）
            var inCrashedThread = false
            var stack: [String] = []
            for line in lines {
                if line.contains("Thread \(analysis["crashed_thread"] ?? "0") Crashed:") {
                    inCrashedThread = true
                    continue
                }
                if inCrashedThread {
                    if line.hasPrefix("Thread") && !line.contains("Crashed") { break }
                    if !line.isEmpty { stack.append(line.trimmingCharacters(in: .whitespaces)) }
                    if stack.count >= 10 { break }
                }
            }
            analysis["stack_top10"] = stack

            // 根因判断
            var rootCause = "未知"
            if let term = analysis["termination_reason"] as? String {
                if term.contains("CODESIGNING") { rootCause = "签名失效" }
                else if term.contains("DYLD") { rootCause = "动态库加载失败" }
                else if term.contains("0xdead10cc") { rootCause = "后台挂起时持有文件锁" }
            }
            if analysis["dyld_error"] != nil { rootCause = "dyld 依赖缺失或符号未找到" }
            if analysis["signature_issue"] != nil { rootCause = "代码签名问题" }
            analysis["root_cause"] = rootCause

            // 修复建议
            switch rootCause {
            case "签名失效":
                analysis["fix"] = "用 TrollStore 重装，或用 ldid -S 重新签名主二进制"
            case "动态库加载失败", "dyld 依赖缺失或符号未找到":
                analysis["fix"] = "检查注入的 dylib 依赖库（otool -L），确认所有依赖在目标设备上存在"
            case "后台挂起时持有文件锁":
                analysis["fix"] = "App 进入后台前关闭文件句柄和数据库连接"
            default:
                analysis["fix"] = "查看完整崩溃日志和调用栈，定位具体代码位置"
            }

            analyses.append(analysis)
        }

        return [
            "bundle_id": bundleId,
            "crash_count": analyses.count,
            "analyses": analyses
        ]
    }
}

// MARK: - 本地 HTTP 服务

final class LocalServerManager {
    static let shared = LocalServerManager()
    private(set) var serverSocket: Int32 = -1
    private var isRunning = false
    private var acceptThread: Thread?

    var port: Int = 0

    func start(port: Int = 8765) -> Bool {
        guard !isRunning else { return true }

        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return false }

        var optval: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            serverSocket = -1
            return false
        }

        guard listen(serverSocket, 16) == 0 else {
            close(serverSocket)
            serverSocket = -1
            return false
        }

        self.port = port
        isRunning = true

        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.start()

        return true
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        acceptThread = nil
    }

    private func acceptLoop() {
        while isRunning && serverSocket >= 0 {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleClient(client)
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }

        var buffer = [CChar](repeating: 0, count: 8192)
        let bytesRead = recv(client, &buffer, 8192, 0)
        guard bytesRead > 0 else { return }

        let request = String(cString: buffer)
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let path = parts[1]

        var responseBody = ""
        var statusCode = 200

        // 路由
        if path == "/health" {
            // v2.9.125：动态读 Info.plist，不再硬编码
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            responseBody = "{\"status\":\"ok\",\"version\":\"\(ver)\",\"port\":\(port)}"
        } else if path == "/tools" {
            let tools = ToolRegistry.shared.allToolNames()
            if let data = try? JSONSerialization.data(withJSONObject: tools),
               let str = String(data: data, encoding: .utf8) {
                responseBody = str
            }
        } else if path.hasPrefix("/api/") {
            // 简单的 API 调用：/api/tool_name?param=value
            let toolName = String(path.dropFirst(5))
            if let tool = ToolRegistry.shared.tool(named: toolName) {
                // 解析 query 参数
                var params: [String: Any] = [:]
                if let queryStart = path.firstIndex(of: "?") {
                    let query = String(path[path.index(after: queryStart)...])
                    for pair in query.components(separatedBy: "&") {
                        let kv = pair.components(separatedBy: "=")
                        if kv.count == 2 {
                            params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                        }
                    }
                }
                do {
                    let result = try tool.invoke(params)
                    // v2.9.125：网关输出与聊天侧统一 CLI 结构（ok/message/data）
                    var data = result
                    data.removeValue(forKey: "message")
                    let msg = (result["message"] as? String)
                        ?? FailureKind.defaultSuccessMessage(name: toolName, result: result)
                    if let d = try? JSONSerialization.data(withJSONObject: ["ok": true, "message": msg, "data": data], options: .prettyPrinted),
                       let str = String(data: d, encoding: .utf8) {
                        responseBody = str
                    }
                } catch {
                    statusCode = 500
                    // 失败也分类输出
                    let text = (error as? MCPError)?.description ?? error.localizedDescription
                    let info = FailureKind.classify(text)
                    let body: [String: Any] = [
                        "ok": false, "message": text,
                        "error": ["code": info.code, "reason": info.reason, "next_step": info.nextStep]
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted),
                       let str = String(data: d, encoding: .utf8) {
                        responseBody = str
                    }
                }
            } else {
                statusCode = 404
                responseBody = "{\"error\":\"tool not found: \(toolName)\"}"
            }
        } else {
            statusCode = 404
            responseBody = "{\"error\":\"not found\"}"
        }

        let response = "HTTP/1.1 \(statusCode) OK\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
        _ = response.withCString { ptr in
            send(client, ptr, Int(strlen(ptr)), 0)
        }
    }
}

final class ServerStartTool: MCPTool {
    let definition = ToolDefinition(
        name: "server.start",
        summary: "Start the local HTTP server. Use for: enable external tools/scripts to call TrollAgent via REST API. Don't use for: stop server (use server.stop), check server status (use server.status). Example: user says '启动本地服务器' → start server.",
        parameters: [
            "port": "Port number (default 8765)"
        ], verified: true, category: "diagnose")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let port = (params["port"] as? Int) ?? 8765
        let ok = LocalServerManager.shared.start(port: port)
        return [
            "message": ok ? "本地 HTTP 服务已启动（127.0.0.1:\(LocalServerManager.shared.port)）" : "启动失败（端口被占用或权限不足）",
            "started": ok,
            "port": LocalServerManager.shared.port,
            "base_url": "http://127.0.0.1:\(LocalServerManager.shared.port)",
            "endpoints": [
                "/health — 健康检查",
                "/tools — 列出所有可用工具",
                "/api/{tool_name}?param=value — 调用工具"
            ]
        ]
    }
}

final class ServerStopTool: MCPTool {
    let definition = ToolDefinition(
        name: "server.stop",
        summary: "Stop the local HTTP server. Use for: turn off the local web server, save battery. Don't use for: start server (use server.start), check server status (use server.status). Example: user says '把本地服务器关了' → stop server.",
        parameters: [:],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        LocalServerManager.shared.stop()
        return ["stopped": true]
    }
}

final class ServerStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "server.status",
        summary: "Check if the local HTTP server is running. Use for: see if server is up, check what port it's on. Don't use for: start server (use server.start), stop server (use server.stop). Example: user says '本地服务器开了吗' → check server status.",
        parameters: [:],
    verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return [
            "running": LocalServerManager.shared.serverSocket >= 0,
            "port": LocalServerManager.shared.port,
            "available_tools": ToolRegistry.shared.allToolNames().count
        ]
    }
}

// MARK: - v3.1.36: server 大工具 + 子命令（合并 3 个 server.* 工具）

final class ServerExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "server",
        summary: "Manage local HTTP server (start/stop/status). Use subcommand to specify action. Use for: start/stop localhost API server. Don't use for: network capture (use network.capture). Example: start → server start port:8080; status → server status. Subcommands: start / stop / status.",
        parameters: [
            "command": "Subcommand: start / stop / status",
            "port": "Port number (for start)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("server", detail: command)
        
        switch command {
        case "start":
            var p: [String: Any] = [:]
            if let port = params["port"] as? Int { p["port"] = port }
            return try ServerStartTool().invoke(p)
            
        case "stop":
            return try ServerStopTool().invoke([:])
            
        case "status":
            return try ServerStatusTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: start/stop/status")
        }
    }
}
