import Foundation

// v2.9.69：质量与诊断工具集
// 1. IPA/dylib 检查器 — 解析架构、签名、entitlements、依赖、注入可行性
// 2. 注入诊断器 — 细分加载失败原因
// 3. 日志采集器 — 收集 App 日志、崩溃日志
// 4. HTTP 抓包 — 网络请求分析

// MARK: - IPA / dylib 检查器

final class IPAInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "ipa.inspect",
        summary: "解析 IPA 文件或已安装 App 的详细信息：架构、签名、entitlements、依赖库、Info.plist、URL schemes、后台模式。用于注入前检查和逆向分析。",
        parameters: [
            "path": "IPA 文件路径或 App Bundle 路径（必填，可用 artifact.find 定位）",
            "detail": "详细程度：basic（默认，架构+签名+版本）或 full（含依赖列表+entitlements全文）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        let detail = (params["detail"] as? String) ?? "basic"

        var result: [String: Any] = ["path": path]

        // 判断是 IPA 还是 App Bundle
        let isIPA = path.hasSuffix(".ipa")
        var bundlePath = path
        var tempDir: String?

        if isIPA {
            // 解压 IPA 到临时目录
            let tmp = NSTemporaryDirectory().appending("ipa_inspect_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/unzip", args: ["-o", path, "-d", tmp])
            // 找到 Payload/*.app
            let payloadDir = tmp.appending("/Payload")
            if let apps = try? FileManager.default.contentsOfDirectory(atPath: payloadDir),
               let appDir = apps.first(where: { $0.hasSuffix(".app") }) {
                bundlePath = payloadDir.appending("/\(appDir)")
                tempDir = tmp
            }
        }

        // 读取 Info.plist
        let plistPath = bundlePath.appending("/Info.plist")
        if let plist = NSDictionary(contentsOfFile: plistPath) {
            let name = plist["CFBundleName"] as? String ?? ""
            let displayName = plist["CFBundleDisplayName"] as? String ?? ""
            let bundleId = plist["CFBundleIdentifier"] as? String ?? ""
            let version = plist["CFBundleShortVersionString"] as? String ?? ""
            let build = plist["CFBundleVersion"] as? String ?? ""
            let exec = plist["CFBundleExecutable"] as? String ?? ""
            let minOS = plist["MinimumOSVersion"] as? String ?? ""
            let platform = plist["DTPlatformName"] as? String ?? ""
            let urlTypes = (plist["CFBundleURLTypes"] as? [[String: Any]])?.count ?? 0
            let bgModes = (plist["UIBackgroundModes"] as? [String]) ?? []
            result["info"] = [
                "CFBundleName": name,
                "CFBundleDisplayName": displayName,
                "CFBundleIdentifier": bundleId,
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
                "CFBundleExecutable": exec,
                "MinimumOSVersion": minOS,
                "DTPlatformName": platform,
                "CFBundleURLTypes": urlTypes,
                "UIBackgroundModes": bgModes
            ]
        }

        // 找到主二进制
        let executable = ((NSDictionary(contentsOfFile: plistPath))?["CFBundleExecutable"] as? String) ?? "App"
        let binaryPath = bundlePath.appending("/\(executable)")

        // 用 ldid 检查签名和 entitlements
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        if !ldidPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) {
            let (_, entOutput) = InjectionManager.shared.spawnRoot(ldidPath, args: ["-e", binaryPath])
            let (_, archOutput) = InjectionManager.shared.spawnRoot("/usr/bin/file", args: [binaryPath])

            result["binary"] = [
                "path": binaryPath,
                "arch": archOutput.contains("arm64") ? "arm64" : (archOutput.contains("armv7") ? "armv7" : "unknown"),
                "entitlements": detail == "full" ? String(entOutput.prefix(3000)) : "已签名（用 detail=full 查看全文）",
                "has_entitlements": !entOutput.isEmpty
            ]

            // 用 otool 检查依赖（如果有 otool）
            let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
            if FileManager.default.fileExists(atPath: otoolPath) {
                let (_, libOutput) = InjectionManager.shared.spawnRoot(otoolPath, args: ["-L", binaryPath])
                let libs = libOutput.components(separatedBy: .newlines)
                    .filter { $0.contains("dylib") || $0.contains("framework") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                result["dependencies"] = detail == "full" ? Array(libs.prefix(30)) : "\(libs.count) 个依赖库（用 detail=full 查看列表）"
            }

            // 检查加密段
            let otoolPath2 = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
            if FileManager.default.fileExists(atPath: otoolPath2) {
                let (_, lcOutput) = InjectionManager.shared.spawnRoot(otoolPath2, args: ["-l", binaryPath])
                result["encrypted"] = lcOutput.contains("LC_ENCRYPTION_INFO")
                result["load_commands"] = lcOutput.components(separatedBy: .newlines).filter { $0.contains("LC_") }.count
            }
        }

        // 清理临时目录
        if let tmp = tempDir {
            try? FileManager.default.removeItem(atPath: tmp)
        }

        // 注入可行性评估
        var injectNotes: [String] = []
        if let bin = result["binary"] as? [String: Any],
           let arch = bin["arch"] as? String {
            if arch != "arm64" {
                injectNotes.append("⚠️ 非 arm64 架构，当前 dylib 可能不兼容")
            }
        }
        if let encrypted = result["encrypted"] as? Bool, encrypted {
            injectNotes.append("⚠️ App 已加密（App Store 下载），注入前需砸壳")
        }
        if injectNotes.isEmpty {
            injectNotes.append("✅ 架构和签名正常，可尝试注入")
        }
        result["inject_feasibility"] = injectNotes

        return result
    }
}

final class DylibInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "dylib.inspect",
        summary: "解析 dylib 文件的详细信息：架构、签名、依赖、导出符号、兼容的 iOS 版本。用于注入前验证 dylib 是否可用。",
        parameters: [
            "path": "dylib 文件路径（必填，可用 artifact.find 定位）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }

        var result: [String: Any] = ["path": path]

        guard FileManager.default.fileExists(atPath: path) else {
            return ["error": "文件不存在", "path": path]
        }

        // 文件大小
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            result["size"] = "\(size) bytes"
        }

        // 架构
        let (_, fileOutput) = InjectionManager.shared.spawnRoot("/usr/bin/file", args: [path])
        result["arch"] = fileOutput.contains("arm64") ? "arm64" : (fileOutput.contains("armv7") ? "armv7" : "unknown")

        // 签名
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        if !ldidPath.isEmpty {
            let (_, entOutput) = InjectionManager.shared.spawnRoot(ldidPath, args: ["-e", path])
            result["signed"] = !entOutput.isEmpty
            result["entitlements"] = String(entOutput.prefix(1000))
        }

        // 依赖
        let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
        if FileManager.default.fileExists(atPath: otoolPath) {
            let (_, libOutput) = InjectionManager.shared.spawnRoot(otoolPath, args: ["-L", path])
            let libs = libOutput.components(separatedBy: .newlines)
                .filter { $0.contains("dylib") || $0.contains("framework") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            result["dependencies"] = Array(libs.prefix(20))
        }

        // 兼容性检查
        var issues: [String] = []
        if result["arch"] as? String != "arm64" {
            issues.append("非 arm64 架构")
        }
        if result["signed"] as? Bool == false {
            issues.append("未签名（TrollStore 环境下 ct_bypass 可绕过）")
        }
        result["compatibility"] = issues.isEmpty ? "✅ 可用于注入" : "⚠️ \(issues.joined(separator: "；"))"

        return result
    }
}

// MARK: - 注入诊断器

final class InjectionDiagnoseTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.diagnose",
        summary: "诊断 dylib 注入失败的具体原因。检查：目标进程状态、dylib 架构/签名、依赖缺失、加载路径、权限、备份文件、Mach-O 完整性。给出明确的修复建议。",
        parameters: [
            "bundle_id": "目标 App 的 Bundle ID（必填）",
            "dylib_path": "要注入的 dylib 路径（可选，不填则检查已注入的 dylib）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let dylibPath = params["dylib_path"] as? String

        var diagnosis: [String: Any] = ["bundle_id": bundleId]
        var issues: [String] = []
        var fixes: [String] = []

        // 1. 检查目标 App 是否存在
        let apps = AppCatalog.list()
        guard let target = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["error": "未找到 App: \(bundleId)", "hint": "用 injection.list 搜索目标 App"]
        }
        diagnosis["app_name"] = target.name
        diagnosis["bundle_path"] = target.path

        // 2. 检查 root 权限
        let probe = DeviceProbe.shared.run()
        diagnosis["root_ready"] = probe.ready
        if !probe.ready {
            issues.append("root 注入环境未就绪")
            fixes.append("在 TrollStore 开启「编辑 Entitlements」后卸载重装")
        }

        // 3. 检查目标进程是否在运行
        let pid = findPid(by: bundleId)
        diagnosis["target_pid"] = pid
        diagnosis["process_running"] = pid > 0
        if pid == 0 {
            issues.append("目标 App 未运行（注入后需重启 App 才能加载 dylib）")
            fixes.append("先打开目标 App，再执行注入")
        }

        // 4. 检查 dylib
        if let dylib = dylibPath {
            diagnosis["dylib_exists"] = FileManager.default.fileExists(atPath: dylib)
            if !FileManager.default.fileExists(atPath: dylib) {
                issues.append("dylib 文件不存在: \(dylib)")
                fixes.append("用 artifact.find 定位正确的 dylib 路径")
            } else {
                // 检查架构
                let (_, fileOutput) = InjectionManager.shared.spawnRoot("/usr/bin/file", args: [dylib])
                let isArm64 = fileOutput.contains("arm64")
                diagnosis["dylib_arch"] = isArm64 ? "arm64" : "unknown"
                if !isArm64 {
                    issues.append("dylib 非 arm64 架构")
                    fixes.append("重新编译 dylib 为 arm64 架构")
                }
            }
        }

        // 5. 检查已注入状态
        let inspect = InjectionManager.shared.inspect(bundleId)
        diagnosis["already_injected"] = inspect["injected"] as? Bool ?? false
        diagnosis["has_backup"] = inspect["hasBackup"] as? Bool ?? false
        if let injected = inspect["injected"] as? Bool, injected {
            // 检查 dylib 是否真的在 Frameworks 目录
            let frameworksDir = target.path.appending("/Frameworks")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
                diagnosis["frameworks_files"] = files.filter { $0.hasSuffix(".dylib") }
            }
        }

        // 6. 检查 Mach-O 完整性（备份是否存在）
        let mainBinary = target.path.appending("/\((NSDictionary(contentsOfFile: target.path.appending("/Info.plist"))?["CFBundleExecutable"] as? String) ?? "")")
        let backupPath = mainBinary.appending(".bak_macho")
        diagnosis["backup_exists"] = FileManager.default.fileExists(atPath: backupPath)

        // 7. 检查注入工具链
        let binaries = ["ldid", "optool", "insert_dylib", "ct_bypass"]
        var binStatus: [String: Bool] = [:]
        for bin in binaries {
            if let path = InjectionManager.shared.binaryPath(bin) {
                binStatus[bin] = FileManager.default.fileExists(atPath: path) && access(path, X_OK) == 0
            } else {
                binStatus[bin] = false
            }
        }
        diagnosis["injection_tools"] = binStatus

        // 总结
        diagnosis["issues"] = issues
        diagnosis["fixes"] = fixes
        diagnosis["verdict"] = issues.isEmpty ? "✅ 注入条件正常，如仍失败请检查 dylib 依赖" : "❌ 发现 \(issues.count) 个问题"

        return diagnosis
    }

    private func findPid(by bundleId: String) -> Int32 {
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
}

// MARK: - 日志采集器

final class LogCollectTool: MCPTool {
    let definition = ToolDefinition(
        name: "log.collect",
        summary: "收集指定 App 的日志和崩溃信息：系统日志、App 标准输出、崩溃报告、注入日志。输出到工作区文件，方便 AI 分析。",
        parameters: [
            "bundle_id": "目标 App 的 Bundle ID（可选，不填则收集 TrollAgent 自身日志）",
            "type": "日志类型：system（系统日志）、crash（崩溃报告）、injection（注入日志）、all（全部，默认）",
            "lines": "收集行数（默认 200）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String ?? Bundle.main.bundleIdentifier ?? ""
        let type = (params["type"] as? String) ?? "all"
        let lines = (params["lines"] as? Int) ?? 200

        let workspace = NSHomeDirectory().appending("/Documents/Workspace/logs")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var collected: [String: String] = [:]

        // 系统日志
        if type == "all" || type == "system" {
            let (_, output) = InjectionManager.shared.spawnRoot("/usr/bin/log", args: ["show", "--last", "\(lines)m", "--predicate", "process == '\(bundleId)'"])
            let path = workspace.appending("/system_\(timestamp).log")
            try? output.write(toFile: path, atomically: true, encoding: .utf8)
            collected["system"] = path
        }

        // 崩溃报告
        if type == "all" || type == "crash" {
            let crashDir = NSHomeDirectory().appending("/Library/Logs/CrashReporter")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) {
                let relevant = files.filter { $0.contains(bundleId) || $0.contains("TrollAgent") }
                for file in relevant.prefix(5) {
                    let src = crashDir.appending("/\(file)")
                    let dst = workspace.appending("/crash_\(file)")
                    try? FileManager.default.copyItem(atPath: src, toPath: dst)
                    collected["crash_\(file)"] = dst
                }
            }
        }

        // 注入日志
        if type == "all" || type == "injection" {
            let injectionLog = NSHomeDirectory().appending("/Documents/Workspace/injection.log")
            if FileManager.default.fileExists(atPath: injectionLog) {
                if let content = try? String(contentsOfFile: injectionLog) {
                    let tail = String(content.components(separatedBy: .newlines).suffix(lines).joined(separator: "\n"))
                    let path = workspace.appending("/injection_\(timestamp).log")
                    try? tail.write(toFile: path, atomically: true, encoding: .utf8)
                    collected["injection"] = path
                }
            }
        }

        // 工具审计日志
        let auditPath = workspace.appending("/audit_\(timestamp).json")
        if let auditData = try? JSONEncoder().encode(AuditLog.shared.entries) {
            try? auditData.write(to: URL(fileURLWithPath: auditPath))
            collected["audit"] = auditPath
        }

        return [
            "bundle_id": bundleId,
            "type": type,
            "collected_files": collected,
            "output_dir": workspace,
            "count": collected.count
        ]
    }
}

// MARK: - HTTP 抓包工具

final class NetworkCaptureTool: MCPTool {
    let definition = ToolDefinition(
        name: "network.capture",
        summary: "HTTP 抓包与分析。需要先注入 NetworkTweak.dylib 到目标 App（内置），注入后 App 的所有 HTTP/HTTPS 请求会记录到本地文件。支持查看请求列表、URL、方法、状态码、Header、JSON 字段分析。",
        parameters: [
            "action": "操作类型：status（查看抓包状态）、start（开始抓包）、stop（停止抓包）、requests（查看请求列表）、analyze（分析请求统计）",
            "bundle_id": "目标 App Bundle ID（start 时必填）",
            "limit": "返回请求数量（默认 50）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String) ?? "status"
        let bundleId = params["bundle_id"] as? String ?? ""
        let limit = (params["limit"] as? Int) ?? 50

        let captureDir = NSHomeDirectory().appending("/Documents/Workspace/network_capture")
        try? FileManager.default.createDirectory(atPath: captureDir, withIntermediateDirectories: true)

        switch action {
        case "status":
            let files = (try? FileManager.default.contentsOfDirectory(atPath: captureDir)) ?? []
            let requestFiles = files.filter { $0.hasSuffix(".json") }
            return [
                "capture_dir": captureDir,
                "captured_sessions": requestFiles.count,
                "network_tweak_builtin": FileManager.default.fileExists(atPath: Bundle.main.path(forResource: "NetworkTweak", ofType: "dylib", inDirectory: "tweaks") ?? ""),
                "hint": "用 action=start 开始抓包，需先注入 NetworkTweak.dylib"
            ]

        case "start":
            guard !bundleId.isEmpty else {
                return ["error": "bundle_id required for start"]
            }
            // 检查 NetworkTweak.dylib 是否内置
            let tweakPath = Bundle.main.path(forResource: "NetworkTweak", ofType: "dylib", inDirectory: "tweaks")
            guard let tweakPath = tweakPath, FileManager.default.fileExists(atPath: tweakPath) else {
                return [
                    "error": "NetworkTweak.dylib 未内置",
                    "hint": "将在后续版本添加；当前可先用 injection.enable 注入其他抓包 dylib"
                ]
            }
            // 注入 NetworkTweak
            let result = try InjectionManager.shared.enable(bundleId: bundleId, dylibName: "@executable_path/NetworkTweak.dylib", dylibSourcePath: tweakPath)
            return [
                "action": "start",
                "bundle_id": bundleId,
                "injection_result": result["injected"] ?? false,
                "hint": "注入成功后重启目标 App，所有 HTTP 请求将记录到 \(captureDir)"
            ]

        case "stop":
            return [
                "action": "stop",
                "hint": "停止抓包：用 injection.disable 移除 NetworkTweak.dylib，或直接杀目标 App 进程"
            ]

        case "requests":
            // 读取捕获的请求
            var allRequests: [[String: Any]] = []
            let files = (try? FileManager.default.contentsOfDirectory(atPath: captureDir)) ?? []
            for file in files.sorted().suffix(3) {
                let path = captureDir.appending("/\(file)")
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    allRequests.append(contentsOf: json)
                }
            }
            let limited = Array(allRequests.suffix(limit))
            return [
                "action": "requests",
                "total": allRequests.count,
                "returned": limited.count,
                "requests": limited
            ]

        case "analyze":
            // 统计分析
            var allRequests: [[String: Any]] = []
            let files = (try? FileManager.default.contentsOfDirectory(atPath: captureDir)) ?? []
            for file in files.sorted().suffix(3) {
                let path = captureDir.appending("/\(file)")
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    allRequests.append(contentsOf: json)
                }
            }
            var methodCount: [String: Int] = [:]
            var statusCount: [String: Int] = [:]
            var hostCount: [String: Int] = [:]
            var errorRequests: [[String: Any]] = []
            for req in allRequests {
                let method = req["method"] as? String ?? "UNKNOWN"
                methodCount[method, default: 0] += 1
                if let status = req["status"] as? Int {
                    statusCount["\(status)", default: 0] += 1
                    if status >= 400 { errorRequests.append(req) }
                }
                if let url = req["url"] as? String,
                   let host = URL(string: url)?.host {
                    hostCount[host, default: 0] += 1
                }
            }
            return [
                "action": "analyze",
                "total_requests": allRequests.count,
                "methods": methodCount,
                "status_codes": statusCount,
                "top_hosts": Array(hostCount.sorted { $0.value > $1.value }.prefix(10)),
                "error_count": errorRequests.count,
                "error_requests": Array(errorRequests.prefix(20))
            ]

        default:
            return ["error": "unknown action: \(action)", "supported": ["status", "start", "stop", "requests", "analyze"]]
        }
    }
}
