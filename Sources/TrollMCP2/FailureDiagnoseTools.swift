import Foundation

// v2.9.132：失败边界一条龙——注入健康检查 + 启动失败判因
// 对齐之前规划的"每个工具失败时先自查原因再给结论"：
// 1. injection.verify：注入后健康检查（Mach-O 标记 / 进程存活 / 崩溃日志 / 结论分级）
// 2. app.diagnose：启动失败自动判因（加密/签名/注入残留/崩溃现场 → 明确原因 + 下一步）

final class InjectionVerifyTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.verify",
        summary: "注入后健康检查：确认 dylib 是否真的加载生效，而不是只看注入标记。检查①Mach-O 加载命令 ②目标进程是否存活 ③最近是否有崩溃记录。返回 healthy / crashed / not_injected / injected_but_dead 结论。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "dylib": "要核对的 dylib 文件名（可选，不填自动检测所有注入资产）"
        ],
        verified: true,
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let wantDylib = params["dylib"] as? String

        let apps = AppCatalog.list()
        guard let app = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["ok": false, "bundle_id": bundleId, "verdict": "not_found",
                    "reason": "未找到 App", "next_step": "用 injection.list 搜索 bundle_id"]
        }

        // 1) Mach-O 加载命令（主二进制 + 注入资产）
        var loadedDylibs: [String] = []
        let mainBinary = app.path + "/" + (((NSDictionary(contentsOfFile: app.path + "/Info.plist"))?["CFBundleExecutable"] as? String) ?? "App")
        if let mo = MachOAnalyzer.analyze(mainBinary) {
            loadedDylibs = mo.dylibs.filter { $0.contains("TrollMCPAgent") || $0.contains("ProbeAgent") || $0.contains("MemoryTweak") || $0.contains(".dylib") }
        }
        // 注入资产（Frameworks 内，TrollFools 策略）
        let assets = InjectionManager.shared.injectedAssets(in: app).map { ($0 as NSString).lastPathComponent }

        // 2) 进程存活
        let pid = findPid(by: bundleId)

        // 3) 崩溃检测：最近 90 秒 CrashReporter 里该 App 的崩溃文件
        var recentCrash: [String: Any]? = nil
        let crashDir = "/var/mobile/Library/Logs/CrashReporter"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) {
            let now = Date().timeIntervalSince1970
            let relevant = files.filter { $0.lowercased().contains(bundleId.lowercased()) || $0.lowercased().contains(app.name.lowercased()) }
            var newest: (String, Date)?
            for f in relevant {
                let p = crashDir + "/" + f
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let mtime = attrs[.modificationDate] as? Date,
                   now - mtime.timeIntervalSince1970 < 90 {
                    if newest == nil || mtime > newest!.1 { newest = (p, mtime) }
                }
            }
            if let n = newest {
                recentCrash = ["path": n.0, "age_s": Int(now - n.1.timeIntervalSince1970),
                               "summary": extractCrashSummary(n.0)]
            }
        }

        // 4) 判定
        let hasMarker = !loadedDylibs.isEmpty || !assets.isEmpty
        var verdict: String
        var reason: String
        var nextStep: String

        if recentCrash != nil {
            verdict = "crashed"
            reason = "检测到最近崩溃：\(recentCrash?["summary"] as? String ?? "")"
            nextStep = "先 injection.disable 或 injection.restore 恢复备份，再检查 dylib 与目标兼容性（架构/依赖/构造函数）；也可 rescue.recover_all 紧急恢复"
        } else if hasMarker && pid > 0 {
            verdict = "healthy"
            reason = "dylib 加载命令存在 + 目标进程存活 + 无最近崩溃"
            nextStep = "可以继续 network_capture / probe 等控制；如需确认 hook 实际触发，注入的 dylib 应写日志到工作区 logs/ 供 log.collect 读取"
        } else if hasMarker && pid == 0 {
            verdict = "injected_but_dead"
            reason = "dylib 已写入加载命令，但目标进程未运行（可能启动后被反注入检测杀掉，或从未启动）"
            nextStep = "用 app.start 启动后立刻再 verify；若仍 dead，参考 app.diagnose 查崩溃原因"
        } else {
            verdict = "not_injected"
            reason = "主二进制/注入资产中未发现注入 dylib"
            nextStep = "先用 injection.enable 注入"
        }

        let result: [String: Any] = [
            "ok": verdict == "healthy",
            "bundle_id": bundleId,
            "verdict": verdict,
            "reason": reason,
            "next_step": nextStep,
            "checks": [
                "macho_dylibs": loadedDylibs,
                "injected_assets": assets,
                "process_alive": pid > 0,
                "pid": pid,
                "recent_crash": recentCrash ?? ([:] as [String: Any])
            ]
        ]
        AuditLog.shared.log("injection.verify", detail: "\(bundleId) → \(verdict)")
        return result
    }
}

final class AppDiagnoseTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.diagnose",
        summary: "启动失败自动判因：检查①是否存在 ②注入残留 ③加密状态 ④签名状态 ⑤最近崩溃现场 ⑥尝试启动。输出明确原因 + 下一步，不再报误导性错误（如把加密解析失败当成 Bundle ID 错）。",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"],
    verified: true,
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let apps = AppCatalog.list()
        guard let app = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["ok": false, "bundle_id": bundleId,
                    "diagnosis": ["not_found": true, "reason": "设备上未安装该 App"],
                    "next_step": "用 injection.list 搜索确认 bundle_id，或 app.install 安装"]
        }

        let binaryPath = app.path + "/" + (((NSDictionary(contentsOfFile: app.path + "/Info.plist"))?["CFBundleExecutable"] as? String) ?? "App")
        var checks: [String: Any] = ["app_name": app.name, "bundle_path": app.path]

        // 1) 注入残留
        let assets = InjectionManager.shared.injectedAssets(in: app)
        let injected = MachOAnalyzer.analyze(binaryPath)?.dylibs.contains(where: { $0.contains("TrollMCPAgent") }) ?? false
        checks["injection"] = ["injected": injected, "assets": assets.map { ($0 as NSString).lastPathComponent }]

        // 2) 加密状态（otool -l 查 LC_ENCRYPTION_INFO）
        var encrypted: Bool? = nil
        let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
        if FileManager.default.fileExists(atPath: otoolPath) {
            let out = InjectionManager.shared.spawnRootDetailed(otoolPath, args: ["-l", binaryPath], timeout: 60).stdout
            encrypted = out.contains("LC_ENCRYPTION_INFO")
        }
        checks["encrypted"] = encrypted

        // 3) 签名状态
        var signed: Bool? = nil
        if let ldid = InjectionManager.shared.binaryPath("ldid") {
            let out = InjectionManager.shared.spawnRootDetailed(ldid, args: ["-e", binaryPath], timeout: 30).stdout
            signed = !out.isEmpty
        }
        checks["signed"] = signed

        // 4) 最近崩溃（10 分钟内）
        var crashSummary: String? = nil
        let crashDir = "/var/mobile/Library/Logs/CrashReporter"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) {
            let now = Date().timeIntervalSince1970
            let relevant = files.filter { $0.lowercased().contains(bundleId.lowercased()) || $0.lowercased().contains(app.name.lowercased()) }
            var newest: (String, Date)?
            for f in relevant {
                let p = crashDir + "/" + f
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let mtime = attrs[.modificationDate] as? Date,
                   now - mtime.timeIntervalSince1970 < 600 {
                    if newest == nil || mtime > newest!.1 { newest = (p, mtime) }
                }
            }
            if let n = newest { crashSummary = extractCrashSummary(n.0) }
        }
        checks["recent_crash"] = crashSummary

        // 5) 尝试启动
        let startTool = AppStartTool()
        let startResult = try? startTool.invoke(["bundle_id": bundleId, "wait_seconds": 3])
        checks["start_attempt"] = startResult ?? ["started": false]

        // 6) 综合判定
        var problems: [String] = []
        var nextSteps: [String] = []
        if injected {
            problems.append("存在注入残留，App 可能因注入崩溃")
            nextSteps.append("先 injection.disable 或 injection.restore 恢复，再启动测试")
        }
        if encrypted == true {
            problems.append("主二进制加密（App Store 正版），无法注入/解析结构")
            nextSteps.append("用 app.decrypt 砸壳后重新安装解密版")
        }
        if signed == false {
            problems.append("无签名信息（未重签名或 ldid 解析失败）")
            nextSteps.append("用 ldid 重新签名或确认 TrollStore 安装状态")
        }
        if let cs = crashSummary {
            problems.append("最近崩溃：\(cs)")
            nextSteps.append("崩溃现场见 CrashReporter；若是注入导致则先恢复再重注")
        }
        if problems.isEmpty {
            nextSteps.append("若仍未启动，检查 dylib 兼容性（架构 arm64/arm64e、依赖库缺失、构造函数崩溃）")
        }

        return ["ok": problems.isEmpty, "bundle_id": bundleId, "checks": checks,
                "problems": problems, "next_steps": nextSteps]
    }
}

// MARK: - 崩溃日志摘要提取（.ips JSON 或 .crash 文本）

func extractCrashSummary(_ path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
          let text = String(data: data, encoding: .utf8) else { return "无法读取" }
    var out: [String] = []
    for line in text.components(separatedBy: .newlines).prefix(60) {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.contains("\"exceptionType\"") || l.contains("exceptionType :") { out.append(l.prefix(160).description) }
        if l.contains("\"termination\"") || l.contains("Termination Reason") { out.append(l.prefix(160).description) }
        if l.contains("Faulty Thread") || l.contains("\"faultingThread\"") { out.append(l.prefix(160).description) }
        if out.count >= 4 { break }
    }
    return out.isEmpty ? String(text.prefix(300)) : out.joined(separator: " | ")
}
