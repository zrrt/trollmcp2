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

    public func isEnabled(name: String) -> Bool {
        let disabled = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        return disabled[name] != false
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

        AuditLog.shared.log("core", detail: "已注册 \(definitions.count) 个工具")
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
