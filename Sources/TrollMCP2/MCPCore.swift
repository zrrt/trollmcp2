import Foundation

// MARK: - 工具定义

public struct ToolDefinition {
    public let name: String
    public let summary: String
    public let parameters: [String: String]

    public init(name: String, summary: String, parameters: [String: String] = [:]) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
    }

    /// v2.9.1：OpenAI / Responses API 要求工具名只能包含 a-zA-Z0-9_-，
    /// 而原版图中的工具名可能含中文、点、空格。转换为合法的 API 名。
    public var apiName: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var sanitized = name.components(separatedBy: allowed.inverted).joined(separator: "_")
        if sanitized.isEmpty { sanitized = "tool" }
        if sanitized.first?.isNumber ?? false { sanitized = "t_\(sanitized)" }
        return sanitized
    }
}

// MARK: - 工具协议

public protocol MCPTool {
    var definition: ToolDefinition { get }
    func invoke(_ params: [String: Any]) throws -> [String: Any]
}

public enum MCPError: Error, CustomStringConvertible {
    case unknownTool(String)
    case invalidParams(String)
    case failed(String)

    public var description: String {
        switch self {
        case .unknownTool(let n): return "unknown tool: \(n)"
        case .invalidParams(let m): return "invalid params: \(m)"
        case .failed(let m): return "tool failed: \(m)"
        }
    }
}

// MARK: - 注册表

public final class ToolRegistry: ObservableObject {
    public static let shared = ToolRegistry()

    private var tools: [String: MCPTool] = [:]
    private var apiNameToOriginal: [String: String] = [:]
    private let lock = NSLock()
    private let disabledKey = "trollmcp2.disabled_tools"

    public func register(_ tool: MCPTool) {
        lock.lock()
        tools[tool.definition.name] = tool
        lock.unlock()
    }

    public var definitions: [ToolDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values.map { $0.definition }.sorted { $0.name < $1.name }
    }

    /// v2.9.15：聊天默认工具白名单。
    /// 根因：80+ 工具全量进 schema 导致每次请求载荷巨大，中转/gpt-5.6 处理极慢甚至超时。
    /// 未显式设置的工具按此白名单决定默认启用；用户显式开/关过的仍以用户为准。
    private static let defaultEnabledTools: Set<String> = [
        "tool_search",   // v2.9.16：渐进式披露元工具，必须始终可用
        "ping", "device.info", "device.probe", "workspace.info",
        "artifact.read_text", "artifact.write_text", "artifact.list",
        "web.search", "knowledge.search",
        "github.account_status", "github.trigger_build", "github.fetch_runs", "github.download_artifact",
        "model.config", "model.authentication", "model.selected_profile_id",
        "skills.list", "skills.read",   // v2.9.17：技能发现/读取
        "gateway.status", "injection.status", "injection.list",
        "injection.enable", "injection.disable", "injection.remove", "injection.inspect",   // v2.9.21：AI 可真实执行注入/移除/检查
        "build.environment", "build.run"
    ]

    public func isEnabled(name: String) -> Bool {
        let disabled = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        if let v = disabled[name] { return v }   // 用户显式设置过，以用户为准
        return Self.defaultEnabledTools.contains(name)
    }

    public func setEnabled(name: String, enabled: Bool) {
        var disabled = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        if enabled {
            disabled.removeValue(forKey: name)
        } else {
            disabled[name] = false
        }
        UserDefaults.standard.set(disabled, forKey: disabledKey)
        objectWillChange.send()
        AuditLog.shared.log("policy", detail: "\(name) \(enabled ? "启用" : "禁用")")
    }

    public var enabledDefinitions: [ToolDefinition] {
        definitions.filter { isEnabled(name: $0.name) }
    }

    /// v2.9.1：生成给 OpenAI API 用的工具 schema，同时建立 apiName → 原名映射，
    /// 供 dispatch 把模型返回的安全名转回真实工具名。
    public func enabledOpenAIToolSchema() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let defs = tools.values.map { $0.definition }.filter { isEnabled(name: $0.name) }
        var used = Set<String>()
        var map = [String: String]()
        var result: [[String: Any]] = []
        for def in defs {
            var safe = def.apiName
            var suffix = 1
            while used.contains(safe) {
                safe = "\(def.apiName)_\(suffix)"
                suffix += 1
            }
            used.insert(safe)
            map[safe] = def.name

            var props: [String: [String: String]] = [:]
            for (k, v) in def.parameters {
                props[k] = ["type": "string", "description": v]
            }
            result.append([
                "type": "function",
                "function": [
                    "name": safe,
                    "description": def.summary,
                    "parameters": [
                        "type": "object",
                        "properties": props,
                        "required": [String](def.parameters.keys)
                    ]
                ]
            ])
        }
        apiNameToOriginal = map
        return result
    }

    /// v2.9.16：tool_search 渐进式披露——按关键词搜索工具名/摘要，返回紧凑清单（不带完整 schema）
    public func searchTools(query: String, limit: Int = 8) -> [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        let q = query.lowercased()
        var hits: [(name: String, summary: String, score: Int)] = []
        for (_, tool) in tools {
            let def = tool.definition
            let nameL = def.name.lowercased()
            let sumL = def.summary.lowercased()
            var score = 0
            if !q.isEmpty {
                if nameL.contains(q) { score += 3 }
                if sumL.contains(q) { score += 2 }
                // 简单分词：每个词命中加分
                for w in q.split(separator: " ").map({ String($0) }) where !w.isEmpty {
                    if nameL.contains(w) { score += 1 }
                    if sumL.contains(w) { score += 1 }
                }
            } else {
                score = 1
            }
            if score > 0 { hits.append((def.name, def.summary, score)) }
        }
        hits.sort { $0.score > $1.score }
        return hits.prefix(limit).map { ["name": $0.name, "summary": $0.summary] }
    }

    /// v2.9.16：返回单个工具的完整 OpenAI function schema（供 tool_search 命中后动态注入下一轮）
    public func openAISchema(for name: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let tool = tools[name] else { return nil }
        let def = tool.definition
        var props: [String: [String: String]] = [:]
        for (k, v) in def.parameters {
            props[k] = ["type": "string", "description": v]
        }
        return [
            "type": "function",
            "function": [
                "name": def.apiName,
                "description": def.summary,
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": [String](def.parameters.keys)
                ]
            ]
        ]
    }

    @discardableResult
    public func dispatch(name: String, params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        var tool = tools[name]
        if tool == nil, let original = apiNameToOriginal[name] {
            tool = tools[original]
        }
        lock.unlock()
        guard let t = tool else { throw MCPError.unknownTool(name) }
        guard isEnabled(name: t.definition.name) else { throw MCPError.failed("工具 \(name) 已被策略禁用") }
        return try t.invoke(params)
    }

    /// 全量内置工具集
    public func registerBuiltinTools() {
        // M1 文件桥 + 基础
        register(ArtifactReadTextTool())
        register(ArtifactWriteTextTool())
        register(ArtifactListTool())
        register(PingTool())
        register(DeviceInfoTool())
        register(DeviceProbeTool())
        register(WorkspaceInfoTool())

        // M2 助理记忆（原版命名）
        register(AssistantMemorySetTool())
        register(AssistantMemoryListTool())
        register(AssistantMemoryDeleteTool())

        // M2 应用与设备
        register(AppCacheInspectTool())
        register(AppCacheClearTool())
        register(AppOpenTool())
        register(AppOpenAndInputTool())
        register(WeChatPrepareMessageTool())

        // M3 注入管理 + 容器
        register(InjectionEnableTool())
        register(InjectionDisableTool())
        register(InjectionStatusTool())
        register(InjectionInspectTool())
        register(InjectionListTool())
        register(InjectionRemoveTool())
        register(ContainerWriteTextTool())
        register(ContainerDeleteTool())

        // M4 Gateway + 自动化（含原版命名）
        register(GatewayStatusTool())
        register(GatewayConnectTool())
        register(NodeInvokeTool())
        register(GatewayNodeInvokeTool())
        register(GatewayChannelSendTool())
        register(GatewayCronCreateTool())
        register(GatewayCronRunTool())
        register(GatewayCronCancelTool())
        register(CronFireTool())
        register(AutomationRunNowTool())
        register(AutomationListTool())
        register(AutomationJobsTool())
        register(AutomationStopTool())
        register(AutomationCancelTool())
        register(AutomationHistoryTool())
        register(AutomationSetEnabledTool())
        register(AutomationStatusTool())

        // M5 系统能力
        register(ContactsSearchTool())
        register(CalendarListTool())
        register(ReminderCreateTool())
        register(LocationGetTool())
        register(NotificationSendTool())
        register(ScanQRTool())
        register(ProcessListTool())

        // M6 编译模式 + 模型配置 + 工作区输出（原版命名）
        register(BuildRunnerTokenTool())
        register(ProjectGenerateTweakTool())
        register(ModelConfigTool())
        register(ModelAuthenticationTool())
        register(ModelSelectedProfileIDTool())
        register(WorkspaceOutputBookmarkTool())
        register(WorkspaceOutputNameTool())

        // M8 本机编译/构建（v2.9.3，设备端编译桥）
        register(BuildEnvironmentTool())
        register(BuildRunTool())

        // M9 GitHub 线上编译（v2.9.9：账号状态 / 触发编译 / 查进度 / 下载产物）
        register(GitHubAccountStatusTool())
        register(GitHubTriggerBuildTool())
        register(GitHubFetchRunsTool())
        register(GitHubDownloadArtifactTool())

        // M7 补齐缺失设备端工具
        register(CalendarCreateEventTool())
        register(ReminderScheduleTool())
        register(ReminderScheduleRecurringTool())
        register(DeviceSnapshotTool())
        register(WebSearchTool())
        register(KnowledgeImportTextTool())
        register(KnowledgeImportFileTool())
        register(KnowledgeSearchTool())
        register(KnowledgeDeleteTool())
        register(PhoneCallTool())
        register(PhoneScheduleCallTool())
        register(SkillsSetEnabledTool())
        register(SkillsListTool())    // v2.9.17：技能可被 AI 发现
        register(SkillsReadTool())    // v2.9.17：技能可被 AI 读取
        register(ToolSearchTool())   // v2.9.16：渐进式披露元工具

        AuditLog.shared.log("core", detail: "已注册 \(definitions.count) 个工具")
    }
}

// MARK: - tool_search 元工具（v2.9.16 渐进式披露）

/// 模型用此工具按关键词搜索全部可用工具，返回名称+摘要清单。
/// 命中后 App 会把对应工具的完整 schema 注入下一轮请求，从而
/// 不必把 80+ 工具全量塞进每次请求（学 OpenClaw / OpenAI Tool Search）。
final class ToolSearchTool: MCPTool {
    let definition = ToolDefinition(
        name: "tool_search",
        summary: "搜索可用工具目录：按关键词返回匹配的工具名与用途摘要。当需要某项能力但当前可用工具中没有时，先用它搜索，再调用搜到的工具。",
        parameters: ["query": "搜索关键词，例如 github、注入、文件、定时", "limit": "最多返回数量（默认 8）"])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let query = (params["query"] as? String) ?? ""
        let limit = (params["limit"] as? NSNumber)?.intValue ?? 8
        let hits = ToolRegistry.shared.searchTools(query: query, limit: max(1, min(limit, 20)))
        return [
            "query": query,
            "total": hits.count,
            "tools": hits,
            "hint": "如需要调用以上某个工具，直接使用它的名字；App 会自动在下一轮加载其定义。"
        ]
    }
}

// MARK: - 工作区

public enum Workspace {
    public static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Workspace", isDirectory: true)
    }

    public static func ensure() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 防目录穿越：解析后必须仍在工作区内
    public static func resolve(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(root.standardizedFileURL.path) else {
            throw MCPError.invalidParams("path escapes workspace: \(path)")
        }
        return url
    }
}
