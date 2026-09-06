import Foundation

// v2.9.71：自动诊断 + 本地 HTTP 服务
// 1. 自动诊断 — 启动失败/崩溃/注入失败自动判因，给出修复建议
// 2. 本地 HTTP 服务 — localhost REST API，其他脚本/工具可调用

// MARK: - 自动诊断工具

final class DiagnoseStartupTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose.startup",
        summary: "自动诊断 App 启动失败原因。检查：签名、架构、依赖、entitlements、注入状态、进程缓存、崩溃日志。给出明确原因和修复步骤。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "auto_fix": "是否自动尝试修复（默认 false，仅诊断）"
        ]
    )

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
        let exec = (try? NSDictionary(contentsOfFile: target.path.appending("/Info.plist"))?["CFBundleExecutable"] as? String) ?? ""
        let binaryPath = target.path.appending("/\(exec)")
        diagnosis["binary_exists"] = FileManager.default.fileExists(atPath: binaryPath)
        if !FileManager.default.fileExists(atPath: binaryPath) {
            causes.append("主二进制不存在")
            fixes.append("重新安装 App")
        }

        // 3. 检查架构
        let (_, fileOutput) = InjectionManager.shared.spawnRoot("/usr/bin/file", args: [binaryPath])
        let isArm64 = fileOutput.contains("arm64")
        diagnosis["arch"] = isArm64 ? "arm64" : "unknown"
        if !isArm64 {
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

        return diagnosis
    }
}

final class DiagnoseCrashTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose.crash",
        summary: "分析指定 App 的最近崩溃日志，自动提取：异常类型、终止原因、崩溃线程、调用栈、dyld 错误、签名问题。给出根因判断和修复建议。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "count": "分析最近几次崩溃（默认 1）"
        ]
    )

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
        let method = parts[0]
        let path = parts[1]

        var responseBody = ""
        var statusCode = 200

        // 路由
        if path == "/health" {
            responseBody = "{\"status\":\"ok\",\"version\":\"2.9.71\",\"port\":\(port)}"
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
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
                       let str = String(data: data, encoding: .utf8) {
                        responseBody = str
                    }
                } catch {
                    statusCode = 500
                    responseBody = "{\"error\":\"\(error)\"}"
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
        summary: "启动本地 HTTP 服务（localhost），其他脚本/工具可通过 REST API 调用 TrollAgent 的所有工具。默认端口 8765。",
        parameters: [
            "port": "端口号（默认 8765）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let port = (params["port"] as? Int) ?? 8765
        let ok = LocalServerManager.shared.start(port: port)
        return [
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
        summary: "停止本地 HTTP 服务。",
        parameters: [:]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        LocalServerManager.shared.stop()
        return ["stopped": true]
    }
}

final class ServerStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "server.status",
        summary: "查看本地 HTTP 服务状态：是否运行、端口、可用工具数量。",
        parameters: [:]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return [
            "running": LocalServerManager.shared.serverSocket >= 0,
            "port": LocalServerManager.shared.port,
            "available_tools": ToolRegistry.shared.allToolNames().count
        ]
    }
}
