import Foundation

// v2.9.73：项目上下文 + 任务模板框架
// 1. ProjectContext — 统一项目状态（目标 App、dylib、配置、历史运行）
// 2. TaskTemplate — 固化常见流程，AI 可一键执行
// 3. 注入自动验证 + 回滚

// MARK: - 项目上下文

final class ProjectContext: ObservableObject {
    static let shared = ProjectContext()

    struct Project: Codable, Identifiable {
        let id: String
        var name: String
        var targetBundleId: String
        var targetAppName: String
        var dylibPath: String
        var dylibName: String
        var createdAt: String
        var lastRunAt: String?
        var runCount: Int
        var successCount: Int
        var notes: String

        init(name: String, targetBundleId: String, targetAppName: String, dylibPath: String = "") {
            self.id = UUID().uuidString
            self.name = name
            self.targetBundleId = targetBundleId
            self.targetAppName = targetAppName
            self.dylibPath = dylibPath
            self.dylibName = URL(fileURLWithPath: dylibPath).lastPathComponent
            self.createdAt = ISO8601DateFormatter().string(from: Date())
            self.lastRunAt = nil
            self.runCount = 0
            self.successCount = 0
            self.notes = ""
        }
    }

    struct RunRecord: Codable, Identifiable {
        let id: String
        let projectId: String
        let timestamp: String
        let taskType: String
        let success: Bool
        let summary: String
        let reportPath: String?
        let durationMs: Int
    }

    @Published private(set) var projects: [Project] = []
    @Published private(set) var currentProjectId: String?
    @Published private(set) var runHistory: [RunRecord] = []

    private let projectsFile: String
    private let historyFile: String

    init() {
        let workspace = NSHomeDirectory().appending("/Documents/Workspace")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        projectsFile = workspace.appending("/projects.json")
        historyFile = workspace.appending("/run_history.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: projectsFile)),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: historyFile)),
           let decoded = try? JSONDecoder().decode([RunRecord].self, from: data) {
            runHistory = decoded
        }
        // 恢复当前项目
        currentProjectId = UserDefaults.standard.string(forKey: "current_project_id")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: URL(fileURLWithPath: projectsFile))
        }
        if let data = try? JSONEncoder().encode(runHistory) {
            try? data.write(to: URL(fileURLWithPath: historyFile))
        }
    }

    var currentProject: Project? {
        projects.first { $0.id == currentProjectId }
    }

    func createProject(name: String, bundleId: String, appName: String, dylibPath: String = "") -> Project {
        let project = Project(name: name, targetBundleId: bundleId, targetAppName: appName, dylibPath: dylibPath)
        projects.append(project)
        currentProjectId = project.id
        UserDefaults.standard.set(project.id, forKey: "current_project_id")
        save()
        return project
    }

    func selectProject(_ id: String) {
        currentProjectId = id
        UserDefaults.standard.set(id, forKey: "current_project_id")
    }

    func deleteProject(_ id: String) {
        projects.removeAll { $0.id == id }
        if currentProjectId == id { currentProjectId = nil }
        save()
    }

    func updateProject(_ id: String, dylibPath: String, notes: String) {
        if let idx = projects.firstIndex(where: { $0.id == id }) {
            projects[idx].dylibPath = dylibPath
            projects[idx].dylibName = URL(fileURLWithPath: dylibPath).lastPathComponent
            projects[idx].notes = notes
            save()
        }
    }

    func recordRun(projectId: String, taskType: String, success: Bool, summary: String, reportPath: String? = nil, durationMs: Int) {
        let record = RunRecord(
            id: UUID().uuidString,
            projectId: projectId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            taskType: taskType,
            success: success,
            summary: summary,
            reportPath: reportPath,
            durationMs: durationMs
        )
        runHistory.insert(record, at: 0)
        if runHistory.count > 500 { runHistory = Array(runHistory.prefix(500)) }

        if let idx = projects.firstIndex(where: { $0.id == projectId }) {
            projects[idx].runCount += 1
            if success { projects[idx].successCount += 1 }
            projects[idx].lastRunAt = record.timestamp
        }
        save()
    }

    func historyFor(projectId: String, limit: Int = 20) -> [RunRecord] {
        Array(runHistory.filter { $0.projectId == projectId }.prefix(limit))
    }
}

// MARK: - 项目上下文工具

final class ProjectTool: MCPTool {
    let definition = ToolDefinition(
        name: "project",
        summary: "项目上下文管理。创建/切换/查看当前项目，AI 自动读取目标 App、dylib、历史运行结果，无需用户重复说明。",
        parameters: [
            "action": "操作：current（查看当前项目）、list（列出所有）、create（新建）、select（切换）、delete（删除）、history（运行历史）",
            "name": "create 时的项目名称",
            "bundle_id": "create 时的目标 App Bundle ID",
            "app_name": "create 时的目标 App 名称",
            "dylib_path": "create/更新时的 dylib 路径",
            "project_id": "select/delete/history 时的项目 ID"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String) ?? "current"

        switch action {
        case "current":
            if let p = ProjectContext.shared.currentProject {
                return [
                    "project": [
                        "id": p.id, "name": p.name,
                        "target_bundle_id": p.targetBundleId,
                        "target_app_name": p.targetAppName,
                        "dylib": p.dylibName,
                        "run_count": p.runCount,
                        "success_count": p.successCount,
                        "success_rate": p.runCount > 0 ? "\(Int(Double(p.successCount) / Double(p.runCount) * 100))%" : "N/A",
                        "last_run": p.lastRunAt ?? "从未运行"
                    ],
                    "hint": "AI 应使用此项目的目标 App 和 dylib，无需用户重复说明"
                ]
            }
            return ["current": nil, "hint": "无当前项目，用 action=create 创建或 action=list 查看"]

        case "list":
            return [
                "projects": ProjectContext.shared.projects.map { [
                    "id": $0.id, "name": $0.name,
                    "target": $0.targetAppName,
                    "runs": $0.runCount,
                    "success": "\($0.successCount)/\($0.runCount)"
                ]},
                "count": ProjectContext.shared.projects.count
            ]

        case "create":
            guard let name = params["name"] as? String,
                  let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("create requires name and bundle_id")
            }
            let appName = params["app_name"] as? String ?? bundleId
            let dylibPath = params["dylib_path"] as? String ?? ""
            let p = ProjectContext.shared.createProject(name: name, bundleId: bundleId, appName: appName, dylibPath: dylibPath)
            return ["created": true, "project_id": p.id, "name": p.name]

        case "select":
            guard let id = params["project_id"] as? String else {
                throw MCPError.invalidParams("select requires project_id")
            }
            ProjectContext.shared.selectProject(id)
            return ["selected": id]

        case "delete":
            guard let id = params["project_id"] as? String else {
                throw MCPError.invalidParams("delete requires project_id")
            }
            ProjectContext.shared.deleteProject(id)
            return ["deleted": id]

        case "history":
            let projectId = params["project_id"] as? String ?? ProjectContext.shared.currentProjectId ?? ""
            let history = ProjectContext.shared.historyFor(projectId: projectId)
            return [
                "project_id": projectId,
                "runs": history.map { [
                    "time": $0.timestamp,
                    "task": $0.taskType,
                    "success": $0.success,
                    "summary": $0.summary,
                    "duration_ms": $0.durationMs
                ]},
                "count": history.count
            ]

        default:
            return ["error": "unknown action: \(action)"]
        }
    }
}

// MARK: - 任务模板

final class TaskTemplateRunner {
    static let shared = TaskTemplateRunner()

    enum TemplateType: String {
        case diagnoseInjection = "diagnose_injection"
        case captureCrash = "capture_crash"
        case injectVerify = "inject_verify"
        case ipaHealth = "ipa_health"
        case performanceRegression = "perf_regression"
    }

    struct TemplateResult {
        let success: Bool
        let summary: String
        let steps: [[String: Any]]
        let reportPath: String?
        let durationMs: Int
    }

    func listTemplates() -> [[String: Any]] {
        return [
            ["id": "diagnose_injection", "name": "诊断注入失败", "desc": "自动检查权限、架构、签名、依赖、进程状态，给出原因和修复方案"],
            ["id": "capture_crash", "name": "采集崩溃现场", "desc": "停止App→采集日志→分析崩溃→生成复现hook模板"],
            ["id": "inject_verify", "name": "注入验证闭环", "desc": "注入→启动→检查加载→验证hook→失败自动回滚"],
            ["id": "ipa_health", "name": "IPA健康检查", "desc": "解析架构/签名/依赖/加密状态，输出注入可行性报告"],
            ["id": "perf_regression", "name": "性能回归测试", "desc": "启动→采样30秒→对比历史→输出回归结论"]
        ]
    }

    func run(_ type: TemplateType, bundleId: String, dylibPath: String? = nil) -> TemplateResult {
        let start = Date()
        var steps: [[String: Any]] = []
        var success = false
        var summary = ""
        var reportPath: String?

        switch type {
        case .diagnoseInjection:
            // 1. 设备环境检查
            let probe = DeviceProbe.shared.run()
            steps.append(["step": "设备环境检查", "success": probe.ready, "detail": probe.ready ? "就绪" : "未就绪"])

            // 2. 注入诊断
            let diagnose = InjectionDiagnoseTool()
            if let result = try? diagnose.invoke(["bundle_id": bundleId]) {
                let issues = result["issues"] as? [String] ?? []
                steps.append(["step": "注入诊断", "success": issues.isEmpty, "detail": issues.isEmpty ? "无问题" : issues.joined(separator: "; ")])

                // 3. 知识库匹配
                if !issues.isEmpty {
                    let kb = KnowledgeBaseTool()
                    if let kbResult = try? kb.invoke(["error": issues.joined(separator: " ")]) {
                        let matches = kbResult["matches"] as? [[String: String]] ?? []
                        if !matches.isEmpty {
                            summary = "发现 \(issues.count) 个问题：\n" + matches.map { "\($0["keyword"] ?? "")：\($0["fix"] ?? "")" }.joined(separator: "\n")
                        } else {
                            summary = "发现 \(issues.count) 个问题，知识库未匹配到已知方案：\n" + issues.joined(separator: "\n")
                        }
                    }
                } else {
                    summary = "注入环境正常，未发现问题"
                    success = true
                }
            }

        case .injectVerify:
            guard let dylib = dylibPath else {
                return TemplateResult(success: false, summary: "需要 dylib_path", steps: [], reportPath: nil, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            }

            // 1. 预检
            let dylibInspect = DylibInspectTool()
            if let dylibResult = try? dylibInspect.invoke(["path": dylib]) {
                let compatible = (dylibResult["compatibility"] as? String)?.contains("✅") ?? false
                steps.append(["step": "dylib预检", "success": compatible, "detail": dylibResult["compatibility"] as? String ?? ""])
                if !compatible {
                    summary = "dylib 不兼容：\(dylibResult["compatibility"] ?? "")"
                    break
                }
            }

            // 2. 杀进程
            let _ = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(findPid(by: bundleId))"])
            Thread.sleep(forTimeInterval: 1)
            steps.append(["step": "停止目标App", "success": true])

            // 3. 注入
            do {
                let injectResult = try InjectionManager.shared.enable(
                    bundleId: bundleId,
                    dylibName: "@rpath/\(URL(fileURLWithPath: dylib).lastPathComponent)",
                    dylibSourcePath: dylib
                )
                let injected = injectResult["injected"] as? Bool ?? false
                steps.append(["step": "执行注入", "success": injected, "detail": injected ? "成功" : "失败"])

                if injected {
                    // 4. 启动验证
                    let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
                    Thread.sleep(forTimeInterval: 5)
                    let pid = findPid(by: bundleId)
                    let started = pid > 0
                    steps.append(["step": "启动验证", "success": started, "detail": started ? "PID=\(pid)" : "启动后闪退"])

                    if started {
                        // 5. 检查 dylib 加载
                        let inspect = InjectionManager.shared.inspect(bundleId)
                        let loaded = inspect["injected"] as? Bool ?? false
                        steps.append(["step": "dylib加载检查", "success": loaded])
                        success = loaded
                        summary = loaded ? "注入成功并验证通过，App 运行正常" : "注入成功但 dylib 未加载"
                    } else {
                        // 启动失败，自动回滚
                        let apps = AppCatalog.list()
                        if let target = apps.first(where: { $0.bundleId == bundleId }) {
                            let exec = (try? NSDictionary(contentsOfFile: target.path.appending("/Info.plist"))?["CFBundleExecutable"] as? String) ?? ""
                            let backup = target.path.appending("/\(exec).bak_macho")
                            if FileManager.default.fileExists(atPath: backup) {
                                let _ = InjectionManager.shared.spawnRoot("/bin/cp", args: [backup, target.path.appending("/\(exec)")])
                                steps.append(["step": "自动回滚", "success": true, "detail": "已恢复备份"])
                            }
                        }
                        // 采集崩溃
                        let crashTool = DiagnoseCrashTool()
                        if let crashResult = try? crashTool.invoke(["bundle_id": bundleId]) {
                            let analyses = crashResult["analyses"] as? [[String: Any]] ?? []
                            if let first = analyses.first, let cause = first["root_cause"] as? String {
                                summary = "注入后启动崩溃，已自动回滚。原因：\(cause)"
                            } else {
                                summary = "注入后启动崩溃，已自动回滚"
                            }
                        }
                    }
                } else {
                    summary = "注入失败"
                }
            } catch {
                summary = "注入异常：\(error.localizedDescription)"
                steps.append(["step": "执行注入", "success": false, "detail": error.localizedDescription])
            }

        case .captureCrash:
            // 1. 停止 App
            let pid = findPid(by: bundleId)
            if pid > 0 { let _ = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(pid)"]) }
            steps.append(["step": "停止App", "success": true])

            // 2. 采集日志
            let logTool = LogCollectTool()
            if let logResult = try? logTool.invoke(["bundle_id": bundleId, "type": "all"]) {
                steps.append(["step": "采集日志", "success": true, "detail": "收集 \(logResult["count"] ?? 0) 个文件"])
            }

            // 3. 分析崩溃
            let crashTool = DiagnoseCrashTool()
            if let crashResult = try? crashTool.invoke(["bundle_id": bundleId]) {
                let analyses = crashResult["analyses"] as? [[String: Any]] ?? []
                if let first = analyses.first {
                    let cause = first["root_cause"] as? String ?? "未知"
                    let fix = first["fix"] as? String ?? ""
                    steps.append(["step": "崩溃分析", "success": true, "detail": cause])
                    summary = "崩溃原因：\(cause)\n修复建议：\(fix)"
                    success = true

                    // 4. 生成复现模板
                    if let crashLog = first["stack_top10"] as? [String] {
                        let reproTool = CrashReproTool()
                        if let reproResult = try? reproTool.invoke(["crash_log": crashLog.joined(separator: "\n"), "bundle_id": bundleId]) {
                            steps.append(["step": "生成复现模板", "success": true, "detail": reproResult["template_path"] as? String ?? ""])
                        }
                    }
                } else {
                    summary = "未找到崩溃日志"
                }
            }

        case .ipaHealth:
            // 用 ipa.inspect
            let apps = AppCatalog.list()
            if let target = apps.first(where: { $0.bundleId == bundleId }) {
                let ipaTool = IPAInspectTool()
                if let result = try? ipaTool.invoke(["path": target.path, "detail": "basic"]) {
                    let feasibility = result["inject_feasibility"] as? [String] ?? []
                    steps.append(["step": "IPA解析", "success": true])
                    summary = feasibility.joined(separator: "\n")
                    success = !feasibility.contains(where: { $0.contains("⚠️") })
                }
            }

        case .performanceRegression:
            // 启动 + 采样
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
            Thread.sleep(forTimeInterval: 3)
            let statsTool = AppStatsTool()
            if let result = try? statsTool.invoke(["bundle_id": bundleId, "duration": 30]) {
                steps.append(["step": "性能采样30秒", "success": true])
                if let cpu = result["cpu"] as? [String: String],
                   let mem = result["memory"] as? [String: Any] {
                    summary = "CPU 平均 \(cpu["avg"] ?? "")%，峰值 \(cpu["max"] ?? "")%\n内存峰值 \(mem["max_kb"] ?? "") KB，\(mem["leak_suspect"] ?? "")"
                    success = true
                }
            }
        }

        // 生成报告
        let workspace = NSHomeDirectory().appending("/Documents/Workspace/reports")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let reportId = UUID().uuidString.prefix(8).description
        let report: [String: Any] = [
            "task_type": type.rawValue,
            "bundle_id": bundleId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "success": success,
            "summary": summary,
            "steps": steps,
            "duration_ms": Int(Date().timeIntervalSince(start) * 1000)
        ]
        reportPath = workspace.appending("/\(type.rawValue)_\(reportId).json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: reportPath!))
        }

        // 记录到项目历史
        if let project = ProjectContext.shared.currentProject {
            ProjectContext.shared.recordRun(
                projectId: project.id,
                taskType: type.rawValue,
                success: success,
                summary: summary,
                reportPath: reportPath,
                durationMs: Int(Date().timeIntervalSince(start) * 1000)
            )
        }

        return TemplateResult(success: success, summary: summary, steps: steps, reportPath: reportPath, durationMs: Int(Date().timeIntervalSince(start) * 1000))
    }
}

final class TaskTool: MCPTool {
    let definition = ToolDefinition(
        name: "task.run",
        summary: "执行任务模板。把常见流程固化成一键执行：诊断注入失败、采集崩溃现场、注入验证闭环（含自动回滚）、IPA健康检查、性能回归。AI 无需逐步调用工具。",
        parameters: [
            "template": "模板ID：diagnose_injection、capture_crash、inject_verify、ipa_health、perf_regression",
            "bundle_id": "目标 App Bundle ID（不填则用当前项目）",
            "dylib_path": "dylib 路径（inject_verify 时必填）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let templateStr = params["template"] as? String,
              let type = TaskTemplateRunner.TemplateType(rawValue: templateStr) else {
            return [
                "error": "unknown template",
                "available": TaskTemplateRunner.shared.listTemplates()
            ]
        }

        var bundleId = params["bundle_id"] as? String ?? ""
        if bundleId.isEmpty, let project = ProjectContext.shared.currentProject {
            bundleId = project.targetBundleId
        }
        guard !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required (或先设置当前项目)")
        }

        let dylibPath = params["dylib_path"] as? String ?? ProjectContext.shared.currentProject?.dylibPath

        let result = TaskTemplateRunner.shared.run(type, bundleId: bundleId, dylibPath: dylibPath)

        return [
            "template": type.rawValue,
            "bundle_id": bundleId,
            "success": result.success,
            "summary": result.summary,
            "steps": result.steps,
            "report_path": result.reportPath ?? "",
            "duration_ms": result.durationMs
        ]
    }
}
