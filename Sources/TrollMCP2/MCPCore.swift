import Foundation

// MARK: - 工具定义

public struct ToolDefinition {
    public let name: String
    public let summary: String
    public let parameters: [String: String]
    /// v3.0.65：返回值说明——AI 知道工具返回什么字段
    public let returns: [String: String]
    /// v2.9.184：真机实测标记——true 表示该工具已在真机远程终端验证过（成功或明确报错分类），
    /// 未验证的工具保持 false，避免"看起来能用"的假象。
    public let verified: Bool
    /// 工具分类（用于 UI 分组显示）：injection / app_control / ui_control / device / filesystem / shell / browser / build / backup / cleanup / macro / knowledge / system / diagnose / analysis / automation / skills / debug / misc
    public let category: String
    /// 给 UI 看的中文描述（为空则 fallback 到 summary）
    public let uiSummary: String
    /// v3.1.1：最低支持的 iOS 主版本（如 16 表示 iOS 16+）。nil 表示所有版本都支持。
    public let minIOSMajor: Int?
    /// v3.1.1：最高支持的 iOS 主版本（如 17 表示只支持到 iOS 17）。nil 表示无上限。
    public let maxIOSMajor: Int?
    /// v3.1.1：是否仅在越狱环境下可用（true = 需要越狱）
    public let requiresJailbreak: Bool
    /// v3.1.1：是否仅在 TrollStore 环境下可用（true = 需要 TrollStore）
    public let requiresTrollStore: Bool
    /// v3.1.26：是否仅远程终端可用（true = 内置 AI 看不到，只在远程 API 可用）
    public let remoteOnly: Bool

    public init(name: String, summary: String, parameters: [String: String] = [:], returns: [String: String] = [:], verified: Bool = false, category: String = "misc", uiSummary: String = "", minIOSMajor: Int? = nil, maxIOSMajor: Int? = nil, requiresJailbreak: Bool = false, requiresTrollStore: Bool = false, remoteOnly: Bool = false) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.returns = returns
        self.verified = verified
        self.category = category
        self.uiSummary = uiSummary
        self.minIOSMajor = minIOSMajor
        self.maxIOSMajor = maxIOSMajor
        self.requiresJailbreak = requiresJailbreak
        self.requiresTrollStore = requiresTrollStore
        self.remoteOnly = remoteOnly
    }

    /// UI 显示用：优先 uiSummary（中文），否则 fallback 到 summary
    public var displaySummary: String {
        uiSummary.isEmpty ? summary : uiSummary
    }

    /// 展示用标记：已验证的工具前缀 ✅已检验
    public var verifiedMark: String {
        verified ? "✅已检验 " : ""
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
    /// v2.9.125：CLI 式失败分类——code + 四分类原因 + 下一步建议。
    /// description 输出为一行：tool failed: [CODE] 原因（分类）下一步：xxx
    case classified(String, code: String, reason: String, nextStep: String)

    public var description: String {
        switch self {
        case .unknownTool(let n): return "unknown tool: \(n)"
        case .invalidParams(let m): return "invalid params: \(m)"
        case .failed(let m): return "tool failed: \(m)"
        case .classified(let m, let code, let reason, let nextStep):
            return "tool failed: [\(code)] \(m)（分类：\(reason)）下一步：\(nextStep)"
        }
    }
}

// MARK: - CLI 式返回协议（v2.9.125）

/// 失败四分类（对齐 Linux exit code 语义）：环境 / 目标 / 参数 / 工具自身 / 未知。
/// 放 dispatch 统一分类，工具层无需逐个改 throw 点。
enum FailureKind {
    static func classify(_ message: String) -> (code: String, reason: String, nextStep: String) {
        let m = message.lowercased()
        // 0) opainject 内存注入专项：被拒（反调试/架构/权限）→ 明确降级路径
        if m.contains("opainject") || m.contains("dlopen") || m.contains("memory injection") {
            return ("INJECT_MEM_FAILED", "目标",
                    "内存注入被拒（反调试/架构/权限）。改试 injection.enable 文件注入（自动备份可回滚），或用 TrollFools 手动注入；大厂 App 可先 app.decrypt 砸壳")
        }
        // 1) 环境：权限 / Entitlements / setuid / 容器写 / 未开权限
        if m.contains("operation not permitted") || m.contains("entitlement")
            || m.contains("setuid") || m.contains("denied") || m.contains("permission")
            || m.contains("未开启") || m.contains("未生效") {
            return ("ENV_PERMISSION", "环境",
                    "TrollStore 开启“编辑 Entitlements”后卸载重装 TrollAgent，再重试")
        }
        // 2) 目标：加密 / 架构 / 兼容 / 闪退 / 无法启动 / 不可注入
        if m.contains("加密") || m.contains("cryptid") || m.contains("encrypted")
            || m.contains("架构") || m.contains("arch") || m.contains("闪退")
            || m.contains("兼容") || m.contains("无法启动") || m.contains("不可注入")
            || m.contains("没有可注入") {
            return ("TARGET_INCOMPATIBLE", "目标",
                    "目标 App 与 dylib 不兼容（加密/架构/依赖），换匹配目标、先砸壳或检查插件兼容性")
        }
        // 3) 参数：not found / 不存在 / 参数 / bundle_id 等
        if m.contains("not found") || m.contains("不存在") || m.contains("未找到")
            || m.contains("参数") || m.contains("invalid") || m.contains("bundle") {
            return ("PARAM_INVALID", "参数",
                    "检查参数（bundle_id / 路径 / 名称）是否正确后重试")
        }
        // 4) 工具自身：缺组件 / 执行失败 / 超时
        if m.contains("未内置") || m.contains("missing") || m.contains("超时")
            || m.contains("timeout") || m.contains("failed") || m.contains("失败") {
            return ("TOOL_FAILED", "工具自身",
                    "工具执行失败，查看 detail/日志定位，或重试一次")
        }
        return ("UNKNOWN", "未知", "查看完整日志后重试")
    }

    /// 判断这个错误能不能自动重试
    static func retryable(_ message: String) -> Bool {
        let m = message.lowercased()
        // 网络错误/超时：可以重试
        if m.contains("timeout") || m.contains("超时")
            || m.contains("network") || m.contains("网络")
            || m.contains("connection") || m.contains("连接")
            || m.contains("unreachable") || m.contains("不可达") {
            return true
        }
        // 临时错误：可以重试
        if m.contains("temporary") || m.contains("临时")
            || m.contains("busy") || m.contains("忙") {
            return true
        }
        // 参数错误/权限错误/目标不兼容：不能重试
        return false
    }

    /// 兜底成功一句话（工具未提供 message 时生成）。
    /// v2.9.125：智能提取器——按 布尔状态 → 数量 → status/summary → 首字段 顺序
    /// 从返回里提取最有信息量的一句，让全部 162 个工具都有可读结论（而非"xx执行成功"）。
    static func defaultSuccessMessage(name: String, result: [String: Any]) -> String {
        // ① 布尔状态类（按词义生成"动作+成功/失败"）
        let boolVerb: [String: String] = [
            "injected": "注入", "ready": "就绪", "started": "启动", "running": "运行",
            "success": "执行", "found": "找到", "deleted": "删除", "created": "创建",
            "updated": "更新", "removed": "移除", "connected": "连接", "loaded": "加载",
            "installed": "安装", "enabled": "启用", "disabled": "停用", "restored": "恢复",
            "cleaned": "清理", "written": "写入", "saved": "保存", "downloaded": "下载",
            "sent": "发送", "completed": "完成", "active": "激活", "available": "可用",
            "canceled": "取消", "killed": "已终止", "resumed": "已恢复", "paused": "已暂停",
            "exists": "存在", "is_core": "常驻", "valid": "有效", "compatible": "兼容"
        ]
        for (key, verb) in boolVerb {
            if let v = result[key] as? Bool {
                return "\(verb)\(v ? "成功" : "失败")"
            }
        }
        // ② 数量类（total/count/matched 等用"条"，size/bytes 用"字节"）
        let countKeys = ["total", "count", "matched", "found",
                         "apps", "tools", "files", "records", "items"]
        for key in countKeys {
            if let n = result[key] as? Int {
                return "共 \(n) 条"
            }
        }
        for key in ["size", "bytes"] {
            if let n = result[key] as? Int {
                return n >= 1048576 ? "\(String(format: "%.1f", Double(n) / 1048576)) MB"
                    : n >= 1024 ? "\(String(format: "%.1f", Double(n) / 1024)) KB"
                    : "\(n) 字节"
            }
        }
        // ③ 状态/结论类字段
        for key in ["status", "verdict", "summary", "result", "state", "conclusion"] {
            if let s = result[key] as? String, !s.isEmpty {
                return s.count > 60 ? String(s.prefix(60)) + "…" : s
            }
        }
        // ④ 首个有值的简短字段（排除大对象/长文本）
        for (k, v) in result {
            if k == "ok" || k == "message" || k == "data" || k == "error" { continue }
            if let s = v as? String, !s.isEmpty, s.count <= 40 {
                return "\(k)=\(s)"
            }
            if let n = v as? NSNumber {
                return "\(k)=\(n)"
            }
        }
        // ⑤ 终极兜底
        return "\(name) 执行成功"
    }
}

// MARK: - 注册表

public final class ToolRegistry: ObservableObject {
    public static let shared = ToolRegistry()

    private var tools: [String: MCPTool] = [:]
    /// v3.1.8：公开工具总数
    public var toolCount: Int { tools.count }
    private var apiNameToOriginal: [String: String] = [:]
    private let lock = NSLock()
    private let disabledKey = "trollmcp2.disabled_tools"
    /// v2.9.22：会话内已授权工具（AI 通过 tool_search 搜索到并决定调用即自动放行，
    /// 无需用户手动开 Toggle）。新会话时清空。
    private var sessionApproved: Set<String> = []
    /// v2.9.26：策略版本号。setEnabled 时递增，通过 @Published 可靠触发
    /// 工具权限策略页刷新（修复 iOS16 List 内 Toggle 只靠 objectWillChange.send()
    /// 刷新不可靠、开关点了没反应/弹回的问题）。
    @Published private(set) var policyRevision = 0

    // v3.0.90：循环提示——记录调用次数，告诉 AI 它调了几次，让 AI 自己判断
    // 不硬拦截，AI 有全局视角，自己决定要不要继续
    private var recentCalls: [String: [Date]] = [:]
    private let loopWindow: TimeInterval = 60.0  // 1 分钟窗口
    private let loopThreshold = 3  // 调 3 次以上就提示

    // v3.0.90：工具结果缓存——5 分钟内同样的调用直接返回缓存，省时间
    private var resultCache: [String: (result: [String: Any], time: Date)] = [:]
    private let defaultCacheWindow: TimeInterval = 300.0  // 默认 5 分钟缓存窗口
    private let longCacheWindow: TimeInterval = 1800.0  // 30 分钟缓存窗口（静态数据）

    /// 哪些工具应该用长缓存（静态数据，不常变）
    private let longCacheTools: Set<String> = [
        "fs_tree", "fs.list", "fs.ls",  // 文件列表
        "device.info", "device.probe",  // 设备信息
        "injection.list", "process.list",  // 进程列表
        "artifact.list", "macro.list",  // 列表类
        "skill.list", "skill.read",  // 技能列表
    ]

    private func callKey(name: String, params: [String: Any]) -> String {
        let sortedParams = params.sorted { $0.key < $1.key }
        let paramStr = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(name):\(paramStr)"
    }

    /// 根据工具名决定缓存窗口
    private func cacheWindow(for toolName: String) -> TimeInterval {
        if longCacheTools.contains(toolName) {
            return longCacheWindow
        }
        return defaultCacheWindow
    }

    private func recordCall(name: String, params: [String: Any]) -> Int {
        let key = callKey(name: name, params: params)
        let now = Date()
        // 清理过期记录
        recentCalls[key] = (recentCalls[key] ?? []).filter { now.timeIntervalSince($0) < loopWindow }
        recentCalls[key]?.append(now)
        if recentCalls[key] == nil { recentCalls[key] = [now] }
        return recentCalls[key]?.count ?? 1
    }

    /// v3.0.90：查缓存——5 分钟内同样的调用直接返回缓存结果
    private func getCachedResult(name: String, params: [String: Any]) -> [String: Any]? {
        let key = callKey(name: name, params: params)
        guard let cached = resultCache[key] else { return nil }
        // 过期了
        let window = cacheWindow(for: name)
        if Date().timeIntervalSince(cached.time) > window {
            resultCache.removeValue(forKey: key)
            return nil
        }
        return cached.result
    }

    /// v3.0.90：存缓存
    private func cacheResult(name: String, params: [String: Any], result: [String: Any]) {
        let key = callKey(name: name, params: params)
        resultCache[key] = (result, Date())
        // 清理过期缓存
        let now = Date()
        for (k, v) in resultCache {
            let window = cacheWindow(for: k.components(separatedBy: ":").first ?? "")
            if now.timeIntervalSince(v.time) > window {
                resultCache.removeValue(forKey: k)
            }
        }
    }

    public func register(_ tool: MCPTool) {
        lock.lock()
        tools[tool.definition.name] = tool
        lock.unlock()
    }

    /// v3.0.71：外部 dylib 注册工具（AI 自我进化——AI 写 dylib 注入自己，注册新工具）
    public func registerExternalTool(_ def: ToolDefinition, handler: @escaping ([String: Any]) throws -> [String: Any]) {
        // v3.0.90：安全检查——AI 自写工具的规则
        let name = def.name.lowercased()

        // 1. 不能覆盖内置工具
        if !name.hasPrefix("custom.") && !name.hasPrefix("user.") {
            print("[TA] ❌ external tool rejected: name must start with 'custom.' or 'user.' (got \(def.name))")
            return
        }

        // 2. 不能包含危险关键词
        let dangerousKeywords = ["shell", "exec", "root", "inject", "download", "upload", "delete", "rm", "sudo", "privileged"]
        for kw in dangerousKeywords {
            if name.contains(kw) {
                print("[TA] ❌ external tool rejected: name contains dangerous keyword '\(kw)'")
                return
            }
        }

        // 3. 不能和现有工具冲突
        if tools[def.name] != nil {
            print("[TA] ❌ external tool rejected: name already exists \(def.name)")
            return
        }

        // 通过检查，注册
        let wrapper = ExternalMCPTool(definition: def, handler: handler)
        register(wrapper)
        print("[TA] ✅ external tool registered: \(def.name)")
    }

    public var definitions: [ToolDefinition] {
        // v3.0.90：去掉锁——只读操作
        return tools.values.map { $0.definition }.sorted { $0.name < $1.name }
    }

    // v2.9.71：本地 HTTP 服务需要的工具查询接口
    public func allToolNames() -> [String] {
        // v3.0.90：去掉锁——只读操作
        return tools.keys.sorted()
    }

    public func tool(named name: String) -> MCPTool? {
        // v3.0.90：去掉锁——只读操作
        return tools[name]
    }

    /// v2.9.15：聊天默认工具白名单。
    /// 根因：80+ 工具全量进 schema 导致每次请求载荷巨大，中转/gpt-5.6 处理极慢甚至超时。
    /// 未显式设置的工具按此白名单决定默认启用；用户显式开/关过的仍以用户为准。
    private static let defaultEnabledTools: Set<String> = [
        "tool_search",   // v2.9.16：渐进式披露元工具，必须始终可用
        "ping", "device.info", "device.probe", "workspace.info",
        "artifact.read_text", "artifact.write_text", "artifact.list",
        "artifact.find",   // v2.9.33/34：递归查找下载产物（与 coreToolNames 保持一致，否则报"未加载"）
        "web.search", "web.fetch", "knowledge.search",
        "fs.tree", "fs.read", "fs.hexdump",   // v2.9.111：Filza 式文件浏览/二进制分析
        "fs.zip", "fs.sql", "fs.grep",        // v2.9.112：ZIP 浏览 / SQLite 查询 / 文本搜索
        "fs.write", "fs.edit", "fs.diff", "fs.hash", "fs.find", "fs.download",  // v2.9.113：读写/对比/校验/搜索/下载
        "fs.plist", "fs.container", "fs.crash", "fs.image_info",  // v2.9.115：plist 键值 / 容器定位 / 崩溃解析 / 图片元数据
        "github.account_status", "github.trigger_build", "github.fetch_runs", "github.download_artifact",
        "model.config", "model.authentication", "model.selected_profile_id",
        "skills.list", "skills.read",   // v2.9.17：技能发现/读取
        "gateway.status", "injection.status", "injection.list", "injection.inspect",   // 查询类
        "build.environment",
        // v2.9.37：内置浏览器（AI 控制入口，搜索即用）
        "browser.status", "browser.snapshot", "browser.click", "browser.type", "browser.eval", "browser.navigate"
    ]

    /// v2.9.31：常驻核心工具名集合（UI 用只读访问）
    public static var coreToolNames: Set<String> { Self._coreToolNames }

    /// v2.9.31：判断工具是否常驻核心（初始请求自动加载，无需搜索）
    /// v3.0.73：根据当前系统指令模式智能叠加常驻工具
    public func isCore(_ name: String) -> Bool {
        if Self.coreToolNames.contains(name) { return true }
        // 叠加当前模式的额外常驻工具
        let extra = SystemPrompts.shared.currentExtraCoreTools
        return extra.contains(name)
    }

    /// v2.9.31：常驻核心工具（借鉴 Anthropic `defer_loading: false` 设计）。
    /// **初始请求只带这些工具**，其余全部工具靠 tool_search 按需搜索加载。
    /// 即使权限策略页全量勾选，初始请求载荷也恒定极小 → 彻底解决"全勾选后变慢"。
    // v3.0.99: 按大厂最佳实践（Claude Code / Cursor），只预加载 5 个最核心工具
    // 其他 200+ 工具全部靠 tool_search 按需发现
    private static let _coreToolNames: Set<String> = [
        // 元工具（必须）
        "tool_search",
        // 全局视角（让 AI 知道有什么工具类别）
        "system.overview",
        // 最常用：读文件
        "fs.read",
        // 最常用：终端
        "shell.exec",
        // 最常用：截图
        "control.screenshot"
    ]

    public func isEnabled(name: String) -> Bool {
        // v2.9.24：改用显式状态字典。用户手动开/关过的工具以显式值为准；
        // 未设置过的工具按白名单决定默认启用。修复"非白名单工具手动开启无效"bug。
        let states = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        if let v = states[name] { return v }
        return Self.defaultEnabledTools.contains(name)
    }

    /// v2.9.22：授权某工具在本会话内可调用（绕过策略禁用）。
    /// v2.9.31：tool_search 搜索命中即调用本方法自动授权，AI 搜索后即可调用，无弹窗。
    public func approveForSession(_ name: String) {
        lock.lock()
        sessionApproved.insert(name)
        lock.unlock()
    }

    /// v2.9.175：本会话已授权工具名（原名，仅返回已注册的），
    /// 供跨消息持久披露——AI 每轮新消息都能看到搜过/授权过的工具 schema，
    /// 根治"tool_search 搜到 app.decrypt 但下一轮够不到"。
    public func approvedToolNames() -> [String] {
        // v3.0.90：去掉锁——只读操作
        return Array(sessionApproved).filter { tools[$0] != nil }
    }

    /// v2.9.22：清空会话授权（新会话时调用）。
    public func clearSessionApproval() {
        lock.lock()
        sessionApproved.removeAll()
        lock.unlock()
    }

    public func isSessionApproved(_ name: String) -> Bool {
        // v3.0.90：去掉锁——只读操作
        return sessionApproved.contains(name)
    }

    public func setEnabled(name: String, enabled: Bool) {
        // v2.9.24：直接写显式状态（true=启用，false=禁用），而非删除 key。
        // 修复"非白名单工具手动开启后开关弹回"bug（旧实现 removeValue 后回落白名单）。
        var states = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        states[name] = enabled
        UserDefaults.standard.set(states, forKey: disabledKey)
        // v2.9.26：@Published 递增 + objectWillChange 双保险，确保 UI 立即刷新
        policyRevision += 1
        objectWillChange.send()
        AuditLog.shared.log("policy", detail: "\(name) \(enabled ? "启用" : "禁用")")
    }

    public var enabledDefinitions: [ToolDefinition] {
        // v3.1.26: 过滤掉 remoteOnly 工具——内置 AI 看不到，只在远程 API 可用
        definitions.filter { isEnabled(name: $0.name) && !$0.remoteOnly }
    }

    /// v2.9.1：生成给 OpenAI API 用的工具 schema，同时建立 apiName → 原名映射，
    /// 供 dispatch 把模型返回的安全名转回真实工具名。
    /// v2.9.31：**只返回常驻核心工具**（coreToolNames），不再全量返回已启用工具。
    /// 其余工具靠 tool_search 按需披露（Anthropic defer_loading 同款设计），
    /// 初始请求载荷恒定极小，全量勾选不影响速度。
    public func enabledOpenAIToolSchema() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let defs = tools.values.map { $0.definition }.filter { isCore($0.name) && isEnabled(name: $0.name) }
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

    /// v3.1.3：向量语义搜索缓存——工具描述的词袋向量（简化版，不需要 embedding 模型）
    private var toolVectors: [String: [String: Double]] = [:]
    private var toolVectorsLoaded = false

    /// v3.1.3：预计算所有工具的词袋向量（简化版语义搜索）
    private func loadToolVectors() {
        guard !toolVectorsLoaded else { return }
        toolVectorsLoaded = true
        for (_, tool) in tools {
            let text = (tool.definition.name + " " + tool.definition.summary).lowercased()
            var vector: [String: Double] = [:]
            // 简单分词：按空格和标点分词
            let words = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            for word in words {
                vector[word, default: 0] += 1
            }
            toolVectors[tool.definition.name] = vector
        }
    }

    /// v3.1.3：计算两个词袋向量的余弦相似度
    private func cosineSimilarity(_ a: [String: Double], _ b: [String: Double]) -> Double {
        var dotProduct: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for (key, valA) in a {
            normA += valA * valA
            if let valB = b[key] {
                dotProduct += valA * valB
            }
        }
        for valB in b.values {
            normB += valB * valB
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dotProduct / (normA.squareRoot() * normB.squareRoot())
    }

    /// v2.9.16：tool_search 渐进式披露——按关键词搜索工具名/摘要，返回紧凑清单（不带完整 schema）
    /// v3.0.90：去重——已会话授权的工具不再重复返回，避免 AI 反复搜以为能找到新工具
    public func searchTools(query: String, limit: Int = 0) -> [[String: String]] {
        // v3.0.90：去掉锁——只读操作，不需要锁，避免死锁
        // v3.1.1：iOS 版本过滤——不支持当前 iOS 版本的工具不返回
        let iosMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let jbStatus = InjectionManager.shared.jailbreakStatus()
        let isJailbroken = jbStatus["is_jailbroken"] as? Bool ?? false

        // v3.0.99: 同义词映射——用户说中文，工具描述是英文，做个映射
        let synonyms: [String: [String]] = [
            "截图": ["screenshot", "screen"],
            "抓包": ["network.capture", "network", "packet", "proxy", "http"],
            "网络抓包": ["network.capture", "network", "packet", "proxy"],
            "网络分析": ["network.capture", "network", "http", "request"],
            "请求": ["network.capture", "http", "request", "api"],
            "请求清单": ["network.capture", "network", "http"],
            "截屏": ["screenshot", "screen"],
            "屏幕": ["screenshot", "screen", "ui"],
            "网页": ["browser", "web", "url"],
            "浏览器": ["browser", "web"],
            "网页内容": ["browser.text", "browser.snapshot"],
            "文本": ["text", "content"],
            "识别": ["ocr", "recognize", "extract"],
            "文字": ["ocr", "text"],
            "注入": ["inject", "injection", "jailbreak"],
            "越狱": ["jailbreak", "ellekit", "jailbreak.inject"],
            "越狱注入": ["jailbreak.inject", "jailbreak"],
            "安装": ["install", "ipa"],
            "卸载": ["uninstall"],
            "启动": ["launch", "app.launch"],
            "重启": ["restart", "app.restart"],
            "进程": ["process", "ps"],
            "文件": ["fs", "file"],
            "读": ["read", "fs.read"],
            "写": ["write", "fs.write"],
            "目录": ["tree", "ls", "fs.tree"],
            "终端": ["shell", "exec"],
            "命令": ["shell", "exec", "command"],
            "点击": ["tap", "click"],
            "点": ["tap", "click"],
            "输入": ["type", "input"],
            "滑动": ["swipe", "scroll"],
            "滚动": ["swipe", "scroll"],
            "设备": ["device", "info"],
            "系统": ["device", "system"],
            "编译": ["build", "compile", "build.runner"],
            "构建": ["build", "compile"],
            "自写工具": ["tool.load_dylib", "self-evolution", "load_dylib"],
            "自我进化": ["tool.load_dylib", "self-evolution"],
            "加载新工具": ["tool.load_dylib", "load_dylib"],
            "写个工具": ["tool.load_dylib", "write_tool", "build"],
        ]

        let q = query.lowercased()
        var hits: [(name: String, summary: String, score: Double)] = []
        loadToolVectors()  // v3.1.3：预计算工具向量（词袋版）

        // v3.1.3：计算查询的词袋向量
        var queryVector: [String: Double] = [:]
        if !q.isEmpty {
            let queryWords = q.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            for word in queryWords {
                queryVector[word, default: 0] += 1
            }
        }

        for (_, tool) in tools {
            let def = tool.definition
            // v3.1.9: 不跳过任何工具——全部返回，AI 一次看完全部
            // 只按 iOS 版本和越狱环境过滤

            // v3.1.1：iOS 版本过滤
            if let minV = def.minIOSMajor, iosMajor < minV { continue }
            if let maxV = def.maxIOSMajor, iosMajor > maxV { continue }

            // v3.1.1：越狱环境过滤
            if def.requiresJailbreak && !isJailbroken { continue }

            let nameL = def.name.lowercased()
            let sumL = def.summary.lowercased()
            var score: Double = 0
            if !q.isEmpty {
                // v3.1.0: 类别前缀匹配——搜 "browser" 就返回所有 browser.* 工具
                if nameL.hasPrefix(q + ".") || nameL.hasPrefix(q + "_") {
                    score += 10  // 类别匹配权重最高
                }
                if nameL.contains(q) { score += 3 }
                if sumL.contains(q) { score += 2 }
                // 简单分词：每个词命中加分
                let queryWords = q.split(separator: " ").map({ String($0) }).filter { !$0.isEmpty }
                for w in queryWords {
                    if nameL.contains(w) { score += 1 }
                    if sumL.contains(w) { score += 1 }
                }
                // v3.0.99: 同义词匹配
                for (cn, enList) in synonyms {
                    if query.contains(cn) {
                        for en in enList {
                            if nameL.contains(en.lowercased()) { score += 2 }
                            if sumL.contains(en.lowercased()) { score += 1 }
                        }
                    }
                }
                // v3.1.3: 类别速查表——常见任务 → 对应的工具类别
                let categoryMap: [String: [String]] = [
                    "截图": ["ui.screenshot", "control.screenshot", "ui"],
                    "抓包": ["network.capture", "debug.dump_network_log"],
                    "注入": ["injection", "jailbreak.inject", "control.inject"],
                    "文件": ["fs.", "bridge.", "artifact."],
                    "浏览器": ["browser."],
                    "自动化": ["automation.", "macro.", "task.run"],
                    "清理": ["cleanup.", "workspace.cleanup", "rescue."],
                    "编译": ["build.", "github."],
                    "崩溃": ["crash", "diagnose.", "log.collect"],
                    "设备": ["device.", "system.overview"],
                    "聊天": ["knowledge.", "assistant.memory"],
                    "微信": ["wechat."],
                    "定位": ["location."],
                    "备份": ["backup."],
                ]
                for (task, cats) in categoryMap {
                    if query.contains(task) {
                        for cat in cats {
                            if nameL.hasPrefix(cat) || nameL.contains(cat) {
                                score += 3
                            }
                        }
                    }
                }
                // v3.1.3: 词袋余弦相似度（简化版，没下载模型时用）
                if let toolVec = toolVectors[def.name], !queryVector.isEmpty {
                    let sim = cosineSimilarity(queryVector, toolVec)
                    score += sim * 5  // 向量相似度权重
                }
            } else {
                score = 1
            }
            if score > 0 { hits.append((def.name, def.summary, score)) }
        }
        hits.sort { $0.score > $1.score }
        // v3.1.9: 返回全部可调用工具——AI 一次看完全部，不用反复搜
        // 只按 iOS 版本和越狱环境过滤，不过滤已授权的
        // limit=0 表示返回全部可调用工具
        if limit <= 0 {
            return hits.map { ["name": $0.0, "summary": $0.1] }
        }
        return hits.prefix(limit).map { ["name": $0.0, "summary": $0.1] }
    }

    /// v2.9.16：返回单个工具的完整 OpenAI function schema（供 tool_search 命中后动态注入下一轮）
    public func openAISchema(for name: String) -> [String: Any]? {
        // v3.0.90：去掉锁——只读操作
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
        // v3.0.90：去掉锁——只读操作（查工具）
        var tool = tools[name]
        if tool == nil, let original = apiNameToOriginal[name] {
            tool = tools[original]
        }
        // v2.9.28：兜底解析——按 apiName（下划线安全名）反向匹配所有注册工具。
        // 修复：tool_search 披露的未启用/敏感工具（如 injection.enable）不在
        // enabledOpenAIToolSchema 的 apiNameToOriginal 映射里（该映射只含已启用工具），
        // 模型按披露 schema 返回 injection_enable 时 dispatch 找不到 → unknown tool。
        if tool == nil {
            tool = tools.values.first { $0.definition.apiName == name }
        }
        // v3.0.90：去掉 lock.unlock()，因为已经去掉了 lock.lock()
        guard let t = tool else { throw MCPError.unknownTool(name) }
        // v2.9.31：去掉授权弹窗。放行 = 策略启用（isEnabled）或会话已授权
        // （tool_search 搜索命中即 approveForSession 自动授权）。
        // 未加载工具（不在常驻、也未搜索过）直接返回错误，提示 AI 先用 tool_search
        // 搜索加载，而不是弹窗打扰用户。
        let originalName = t.definition.name
        // v2.9.34：放行 = 策略启用 或 会话已授权 或 常驻核心工具。
        // 修复 bug：coreToolNames 里的工具（如 artifact.find）schema 已发给模型，
        // 但 defaultEnabledTools 未收录时 isEnabled 返回 false → 报"未加载"。
        // 常驻核心必然放行（它本来就在初始请求里，用户开关不应对它二次拦截）。
        if isEnabled(name: originalName) || isSessionApproved(originalName) || isCore(originalName) {
            // v2.9.36：统一审计（老 MCP 样式：成功/失败 · 权限 · 耗时 · 数据量）
            let start = CFAbsoluteTimeGetCurrent()
            let perm = Self.permissionLabel(originalName)
            do {
                // v3.0.90：记录调用次数，告诉 AI 它调了几次，让 AI 自己判断
                let callCount = recordCall(name: originalName, params: params)
                // v2.9.72：工作流可视化
                WorkflowManager.shared.addStep(name: originalName, tool: originalName)

                // v3.0.90：结果缓存——5 分钟内同样的调用直接返回缓存
                if let cached = getCachedResult(name: originalName, params: params) {
                    WorkflowManager.shared.updateStep(tool: originalName, detail: "cached", success: true)
                    var cachedData = Self.compactResult(cached)
                    cachedData.removeValue(forKey: "message")
                    cachedData["_call_count"] = callCount
                    cachedData["_cached"] = true
                    return ["ok": true, "data": cachedData]
                }

                // v3.0.90：工具执行超时保护——15 秒没返回就报错，防止一直卡着
                var timedOut = false
                let timeoutWorkItem = DispatchWorkItem {
                    timedOut = true
                    WorkflowManager.shared.updateStep(tool: originalName, detail: "⏱ 超时（15s）", success: false)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutWorkItem)

                // v3.1.5: 自动重试——网络错误/超时自动重试一次
                var result: [String: Any]
                do {
                    result = try t.invoke(params)
                } catch {
                    // 异常抛出的错误：判断能不能重试
                    let errStr = "\(error)"
                    if FailureKind.retryable(errStr) && callCount == 1 {
                        // 自动重试一次
                        WorkflowManager.shared.updateStep(tool: originalName, detail: "🔄 自动重试...", success: false)
                        Thread.sleep(forTimeInterval: 1.0)  // 等 1 秒再重试
                        result = try t.invoke(params)
                    } else {
                        throw error
                    }
                }
                timeoutWorkItem.cancel()
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                // v2.9.134：返回式错误统一识别——工具 return ["error":...] / ["ok": false] /
                // ["status": "failed"] 不再伪装成功（旧版 ok 恒为 true，AI 无法分辨成败，
                // 即"死结果"根因）。统一走 code/reason/nextStep 失败路径。
                if let errMsg = Self.extractReturnedError(result) {
                    let info = FailureKind.classify(errMsg)
                    // v3.1.5: 返回式错误也自动重试一次
                    if FailureKind.retryable(errMsg) && callCount == 1 {
                        WorkflowManager.shared.updateStep(tool: originalName, detail: "🔄 自动重试...", success: false)
                        Thread.sleep(forTimeInterval: 1.0)  // 等 1 秒再重试
                        do {
                            result = try t.invoke(params)
                        } catch {
                            // 重试还是失败，继续走失败路径
                            AuditLog.shared.logTool(originalName, status: .failure,
                                                    elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                    detail: errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                            WorkflowManager.shared.updateStep(tool: originalName, detail: errMsg, success: false)
                            if callCount >= loopThreshold {
                                throw MCPError.failed("🚫 LOOP BLOCKED: You've called this tool \(callCount) times with same params and it keeps failing with the same error. STOP. Do NOT call it again. Try a completely different approach, or ask the user what to do. Error: \(errMsg)")
                            }
                            throw MCPError.classified(errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                        }
                        // 重试成功了，继续走成功路径（如果还有返回式错误，继续往下走会再检查一次）
                        if Self.extractReturnedError(result) != nil {
                            // 重试还是返回式错误，继续走失败路径
                            let newErrMsg = Self.extractReturnedError(result)!
                            let newInfo = FailureKind.classify(newErrMsg)
                            AuditLog.shared.logTool(originalName, status: .failure,
                                                    elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                    detail: newErrMsg, code: newInfo.code, reason: newInfo.reason, nextStep: newInfo.nextStep)
                            WorkflowManager.shared.updateStep(tool: originalName, detail: newErrMsg, success: false)
                            throw MCPError.classified(newErrMsg, code: newInfo.code, reason: newInfo.reason, nextStep: newInfo.nextStep)
                        }
                        // 重试成功，继续往下走
                    } else {
                        AuditLog.shared.logTool(originalName, status: .failure,
                                                elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                detail: errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                        WorkflowManager.shared.updateStep(tool: originalName, detail: errMsg, success: false)
                        // v3.1.1: 连续失败 3 次就拦截，不让 AI 继续循环
                        if callCount >= loopThreshold {
                            throw MCPError.failed("🚫 LOOP BLOCKED: You've called this tool \(callCount) times with same params and it keeps failing with the same error. STOP. Do NOT call it again. Try a completely different approach, or ask the user what to do. Error: \(errMsg)")
                        }
                        throw MCPError.classified(errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                    }
                }
                let bytes = Self.resultBytes(result)
                AuditLog.shared.logTool(originalName, status: .success,
                                        elapsedMs: elapsedMs, dataBytes: bytes, permission: perm)
                WorkflowManager.shared.updateStep(tool: originalName, detail: "\(elapsedMs)ms", success: true)

                // v3.0.90：存结果缓存（成功才存，失败不缓存）
                cacheResult(name: originalName, params: params, result: result)

                // v2.9.125：CLI 式统一返回——顶层只留 ok/message，细节收进 data。
                // AI 读 message 一眼判成败；需要排障才展开 data。
                // v2.9.137：结果摘要化——data 内大数组（>20）/大字符串（>4000）
                // 递归压缩，复合工具诊断结论前置、细节按需取，防大结果占满上下文。
                var data = Self.compactResult(result)
                data.removeValue(forKey: "message")
                // v3.0.90：告诉 AI 它调了几次，让 AI 自己判断是不是在循环
                data["_call_count"] = callCount
                if callCount >= loopThreshold {
                    data["_loop_hint"] = "⚠️ You've called this tool \(callCount) times with the same params in the last \(Int(loopWindow))s. If the result is the same, you're probably looping. Try a different approach or ask the user."
                }
                // v2.9.167：_noMessage 标记——高频元工具（如 tool_search）返回里
                // 明确不需要顶层 message（total/tools 已自解释），省 ~10 token/次
                if result["_noMessage"] as? Bool == true {
                    data.removeValue(forKey: "_noMessage")
                    return ["ok": true, "data": data]
                }
                let msg = (result["message"] as? String)
                    ?? FailureKind.defaultSuccessMessage(name: originalName, result: result)
                // v2.9.168：全局紧凑规则——data 序列化后 >600 字节（有实质内容自解释）
                // 时自动去掉顶层 message 省 token（201 个工具大结果统一生效）；
                // 小结果保留 message（"砸壳完成：xxx"这类结论句帮 AI 秒判，不丢判断力）。
                if Self.resultBytes(data) > 600 {
                    return ["ok": true, "data": data]
                }
                return ["ok": true, "message": msg, "data": data]
            } catch {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let errDesc = (error as? MCPError)?.description ?? error.localizedDescription
                // v2.9.128：失败记录 CLI 四分类 code/reason/nextStep（供健康度聚合 + AI 自查）
                let classified: MCPError
                if case MCPError.classified(_, code: let c, reason: let r, nextStep: let n) = error {
                    classified = MCPError.classified(errDesc, code: c, reason: r, nextStep: n)
                } else {
                    let info = FailureKind.classify(errDesc)
                    classified = MCPError.classified(errDesc, code: info.code, reason: info.reason, nextStep: info.nextStep)
                }
                let (cCode, cReason, cNext) = Self.unpack(classified)
                AuditLog.shared.logTool(originalName, status: .failure,
                                        elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                        detail: errDesc, code: cCode, reason: cReason, nextStep: cNext)
                WorkflowManager.shared.updateStep(tool: originalName, detail: errDesc, success: false)
                throw classified
            }
        }
        // v3.1.9: 工具未授权 → 自动授权 + 返回"已加载，请重新调用"
        // 这样 AI 不用反复搜 tool_search，直接调用时自动加载
        approveForSession(originalName)
        throw MCPError.failed("tool \(originalName) 已加载，schema 已注入下一轮，请重新调用")
    }

    // v2.9.128：解包 classified 的 code/reason/nextStep（审计记录用）
    private static func unpack(_ err: MCPError) -> (String, String, String) {
        if case MCPError.classified(_, code: let c, reason: let r, nextStep: let n) = err {
            return (c, r, n)
        }
        let info = FailureKind.classify(err.description)
        return (info.code, info.reason, info.nextStep)
    }

    /// v2.9.134：提取"返回式错误"（工具不 throw 而是 return ["error":...]/["ok":false]/
    /// ["status":"failed"]）。返回 nil 表示该结果应视为成功。
    /// v2.9.137：结果摘要化（递归）——大数组保持数组但截断并末尾加省略标记，
    /// 大字符串截断并附总长度。返回后 AI 仍能读结论字段，细节可带 limit 重取。
    /// `content` 字段（fs.read/artifact.read_text 的文件内容）保留完整——
    /// 它们已由 max_bytes 参数控制读取量，不能再截断。
    /// v2.9.168：通用字段瘦身（全部工具生效，向 tool_search 看齐）——
    /// hint 截 60、summary 截 30、删空字符串值。结构信息不删，只去冗余。
    static func slim(_ d: [String: Any]) -> [String: Any] {
        var nd = d
        if let h = nd["hint"] as? String, h.count > 60 { nd["hint"] = String(h.prefix(60)) + "…" }
        if let sm = nd["summary"] as? String, sm.count > 30 { nd["summary"] = String(sm.prefix(30)) + "…" }
        for (k, v) in nd where (v as? String)?.isEmpty == true {
            nd.removeValue(forKey: k)
        }
        return nd
    }

    /// v2.9.164：大字符串落盘到工作区 tool_spill/（完整内容保留，AI 按路径再读）
    static func spillLarge(_ key: String, _ content: String) -> String {
        let dir = Workspace.root.appendingPathComponent("tool_spill", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "spill_\(Int(Date().timeIntervalSince1970))_\(key.replacingOccurrences(of: "/", with: "_")).txt"
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    static func compactResult(_ root: [String: Any], arrLimit: Int = 20, strLimit: Int = 4000) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in root {
            switch v {
            case let s as String:
                // v2.9.164：先压多余空行（\n{3,}→\n\n）与行尾空格——日志/hexdump 的空行
                // 在模型侧也是 token，压缩后单次可省数百 token，且不破坏内容结构。
                var t = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                t = t.split(separator: "\n", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.joined(separator: "\n")
                if k == "content" || t.count <= strLimit {
                    out[k] = t
                } else {
                    // 截断 + 落盘：完整内容写工作区 tool_spill/，AI 需要细节可再读文件
                    let spillPath = Self.spillLarge(k, t)
                    out[k] = String(t.prefix(strLimit)) + "\n…[截断 共\(t.count)字符，完整内容: \(spillPath)]"
                }
            case let arr as [[String: Any]]:
                if arr.count > arrLimit {
                    var cut = Array(arr.prefix(arrLimit))
                    cut.append(["note": "…[共\(arr.count)项，已截断，仅显示前 \(arrLimit) 项]"])
                    out[k] = cut
                } else {
                    out[k] = arr.map { slim(compactResult($0)) }
                }
            case let arr as [Any]:
                if arr.count > arrLimit {
                    var cut = Array(arr.prefix(arrLimit))
                    cut.append("…[共\(arr.count)项，已截断，仅显示前 \(arrLimit) 项]")
                    out[k] = cut
                } else {
                    out[k] = arr.map { ($0 as? [String: Any]).map { Self.slim(Self.compactResult($0)) } ?? $0 }
                }
            case let d as [String: Any]:
                out[k] = slim(compactResult(d))
            default:
                out[k] = v
            }
        }
        return out
    }

    static func extractReturnedError(_ result: [String: Any]) -> String? {
        // ① 显式 ok:false
        if result["ok"] as? Bool == false {
            return Self.errorMessage(from: result["error"], fallback: "工具返回 ok=false")
        }
        // ② error 键（String 或 [String:Any] 字典）
        // v3.1.8：nil error 不应该被当成错误——只有 error 有值时才算
        if let errBox = result["error"], !(errBox is NSNull) {
            return Self.errorMessage(from: errBox, fallback: "工具返回错误（未提供原因）")
        }
        // ③ status 失败态
        if let st = result["status"] as? String, ["failed", "error", "failure"].contains(st.lowercased()) {
            return Self.errorMessage(from: result["reason"] ?? result["error"], fallback: "工具返回失败状态 \(st)")
        }
        return nil
    }

    private static func errorMessage(from box: Any?, fallback: String) -> String {
        if let s = box as? String, !s.isEmpty { return s }
        if let d = box as? [String: Any] {
            for k in ["reason", "message", "error", "detail"] {
                if let s = d[k] as? String, !s.isEmpty { return s }
            }
            if let s = d["description"] as? String, !s.isEmpty { return s }
        }
        return fallback
    }

    // v2.9.36：权限标签（对齐老 MCP readOnly/privilegedRead/write 语义，按工具名前缀粗分）
    private static func permissionLabel(_ name: String) -> String {        let write = ["open", "open_and_input", "enable", "disable", "remove", "write",
                     "set", "delete", "clear", "run", "send", "connect", "create",
                     "cancel", "fire", "schedule", "prepare", "stop", "import",
                     "generate", "config", "set_enabled", "output", "approve", "refresh"]
        for w in write where name.contains(w) { return "write" }
        if name.contains("cache") { return "privilegedRead" }
        return "readOnly"
    }

    // v2.9.36：结果数据量（JSON 序列化字节估算）
    private static func resultBytes(_ result: [String: Any]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return 0 }
        return data.count
    }

    /// 全量内置工具集
    public func registerBuiltinTools() {
        // M1 文件桥 + 基础
        register(ArtifactReadTextTool())
        register(ArtifactWriteTextTool())
        register(ArtifactListTool())
        register(ArtifactFindTool())   // v2.9.33：递归查找下载产物 dylib/deb
        register(PingTool())
        register(DeviceInfoTool())
        register(DeviceProbeTool())
        register(MemoryTweakTool())   // v2.9.60：H5GG式内存修改（需先注入MemoryTweak.dylib）
        // v2.9.75：ControlAgent 通用 UI 控制（注入后 AI 可控制任意 App UI）
        register(ControlInjectTool())
        register(ControlStatusTool())
        register(ControlUITreeTool())
        register(ControlScreenshotTool())
        register(ControlTapTool())
        register(ControlSwipeTool())
        register(ControlTypeTool())
        register(ControlKeyTool())
        register(WorkspaceInfoTool())
        register(ToolHealthTool())   // v2.9.128：工具健康度自查
        // v2.9.128：清理中心（对齐 Fuck 工具箱清理能力 + AI 清理亮点）
        register(CleanupScanTool())
        register(CleanupExecuteTool())
        register(CleanupAiTool())
        // v2.9.128：系统级清理（Fuck 工具箱系统清理页能力，AI 可调用）
        register(SystemCleanupScanTool())
        register(SystemCleanupExecuteTool())

        // M2 助理记忆（原版命名）
        register(AssistantMemorySetTool())
        register(AssistantMemoryListTool())
        register(AssistantMemoryDeleteTool())

        // M2 应用与设备
        register(AppCacheInspectTool())
        register(AppCacheClearTool())
        // register(AppOpenTool())  // 合并到 app.start（多级策略更可靠），重复
        register(AppOpenAndInputTool())
        register(AppDepsTool())
        // register(WeChatPrepareMessageTool())  // 去掉，半自动粘贴没用

        // v3.0.90：系统概览工具（AI 全局视角目录）
        register(SystemOverviewTool())
        register(SystemLessonsTool())  // v3.0.90：AI 经验教训库
        register(TaskProgressTool())   // v3.0.90：任务进度跟踪
        register(VerifyInjectTool())   // v3.0.90：结果验证
        register(VerifyFileTool())
        register(VerifyAppRunningTool())

        // M3 注入管理 + 容器
        register(InjectionEnableTool())
        register(InjectionDisableTool())
        register(InjectionStaticTool())  // v3.0.89：iOS 17 兼容静态注入
        register(InjectionStatusTool())
        register(InjectionInspectTool())
        register(InjectionListTool())
        register(JailbreakStatusTool())  // v3.1.1：Jailbreak 状态检测
        register(JailbreakInjectTool())   // v3.1.1：ElleKit 运行时注入
        register(InjectionRemoveTool())
        register(InjectionRestoreTool())
        register(InjectionEnablePersistedTool())
        register(RescueScanTool())
        register(RescueRecoverAllTool())
        register(RescueCleanupTool())
        // v2.9.90：高级工具组（内存注入/类探测/配置化 Hook/设备伪装）
        register(InjectionMemTool())
        register(ProbeInspectTool())
        register(HookApplyTool())
        register(DeviceFakeTool())
        register(DeviceRestoreTool())
        // v2.9.95：设备指纹 / 容器 / entitlements（对齐 Fuck 工具箱 + 绿盾式）
        register(AppEntitlementsTool())
        register(KeychainWipeTool())
        register(AdvertisingTool())
        register(IdfvTool())
        register(RefreshContainerTool())
        register(ContainerWriteTextTool())
        register(ContainerDeleteTool())
        // v2.9.99：一键新机（绿盾式组合）
        register(NewDeviceTool())
        // v2.9.100：AI 分析引擎
        register(AiAnalyzeTool())

        // v2.9.68：SSH 远程连接 + 应用解密
        register(SSHTool())
        register(SCPTool())
        register(AppDecryptTool())
        register(AppReplaceDecryptedTool())
        register(AppEncryptInfoTool())

        // v2.9.69：质量与诊断工具
        register(IPAInspectTool())
        register(DylibInspectTool())
        register(InjectionDiagnoseTool())
        register(LogCollectTool())
        register(NetworkCaptureTool())

        // v2.9.70：进程管理 + 测试编排器
        register(AppStartTool())
        register(AppStopTool())
        register(AppRestartTool())
        register(AppStatusTool())
        register(AppStatsTool())
        register(TestRunTool())

        // v2.9.71：自动诊断 + 本地 HTTP 服务
        register(DiagnoseStartupTool())
        register(DiagnoseCrashTool())
        register(ServerStartTool())
        register(ServerStopTool())
        register(ServerStatusTool())

        // v2.9.72：知识库 + 清理 + 符号 + 插件 + 兼容矩阵 + 崩溃复现
        register(KnowledgeBaseTool())
        register(WorkspaceCleanupTool())
        register(BinarySymbolsTool())
        register(PluginTool())
        register(CompatibilityTool())
        register(CrashReproTool())

        // v2.9.73：项目上下文 + 任务模板
        register(ProjectTool())
        register(TaskTool())

        // M4 Gateway + 自动化（含原版命名）
        // register(GatewayStatusTool())  // 和远程终端重复，去掉
        // register(GatewayConnectTool())
        // register(GatewayNodeInvokeTool())
        // register(GatewayChannelSendTool())
        // register(GatewayCronCreateTool())
        // register(GatewayCronRunTool())
        // register(GatewayCronCancelTool())
        register(CronFireTool())
        register(AutomationRunNowTool())
        register(AutomationListTool())
        register(AutomationJobsTool())
        register(AutomationStopTool())
        // register(AutomationCancelTool())  // 合并到 automation.stop，重复
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
        register(ShellExecTool())   // v3.0.28：内置终端，执行 shell 命令

        // M5.5 内置浏览器（v2.9.37：AI 可控，蓝框高亮元素；v2.9.88：+wait/text/scroll/submit）
        register(BrowserStatusTool())
        // register(BrowserOpenTool())  // 合并到 browser.navigate（已支持 url 参数），重复
        register(BrowserWaitTool())
        register(BrowserSnapshotTool())
        register(BrowserClickTool())
        register(BrowserTypeTool())
        register(BrowserSubmitTool())
        register(BrowserTextTool())
        register(BrowserScrollTool())
        register(BrowserEvalTool())
        // v2.9.130：表单整表填充 / 字段扫描 / 元素等待（对齐 Playwright fill + waitFor）
        register(BrowserFormFieldsTool())
        register(BrowserFillFormTool())
        register(BrowserWaitForTool())
        // v2.9.131：AI 安装/卸载 App（trollstorehelper 优先）——补全下载→安装→注入→控制链路
        register(AppInstallTool())
        register(AppUninstallTool())
        register(AppDuplicateTool())
        // v2.9.132：失败边界一条龙——注入健康检查 + 启动失败判因
        register(InjectionVerifyTool())
        register(AppDiagnoseTool())
        register(BrowserNavigateTool())

        // M6 编译模式 + 模型配置 + 工作区输出（原版命名）
        register(BuildRunnerTokenTool())
        register(ProjectGenerateTweakTool())
        register(ModelConfigTool())
        register(ModelUpdateTool())
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
        register(WebFetchTool())   // v2.9.79：网页抓取（搜索后读原文）
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
        register(ClipboardReadTool())   // v2.9.108：剪贴板读取（ios-mcp 借鉴）
        register(ClipboardWriteTool())  // v2.9.108：剪贴板写入（ios-mcp 借鉴）
        register(FSTreeTool())      // v2.9.111：Filza 式目录浏览
        register(FSReadTool())      // v2.9.111：文件读取（文本/plist/SQLite/二进制识别）
        register(FSHexdumpTool())   // v2.9.111：二进制十六进制查看
        register(FSZipTool())       // v2.9.112：ZIP/IPA 归档浏览与条目读取
        register(FSSQLTool())       // v2.9.112：SQLite 只读查询（Filza SQLite3 编辑器）
        register(FSGrepTool())      // v2.9.112：目录文本关键词搜索
        register(FSWriteTool())     // v2.9.113：写文件（带 .bak 备份）
        register(FSEditTool())      // v2.9.113：行级/片段编辑（带 .bak 备份）
        register(FSDiffTool())      // v2.9.113：文件对比（文本 diff / 二进制哈希）
        register(FSHashTool())      // v2.9.113：文件哈希与元数据
        register(FSFindTool())      // v2.9.113：文件名搜索
        register(FSDownloadTool())  // v2.9.113：下载到工作区
        register(FSPropertyListTool()) // v2.9.115：plist 键值读写（Filza 属性表编辑器）
        register(FSContainerTool())    // v2.9.115：App 容器路径四件套
        register(FSCrashTool())        // v2.9.115：崩溃日志解析
        register(FSImageInfoTool())    // v2.9.115：图片元数据

        // v2.9.139：AI 控制任意 App（HID 触摸注入 + 进度横幅 + 控制会话）
        register(UITapTool())
        register(UISwipeTool())
        register(UILongPressTool())
        register(UIClipboardTool())
        register(UIScreenshotTool())
        register(ProgressNotifyTool())
        register(ControlBeginTool())
        register(ControlUpdateTool())
        register(ControlFinishTool())
        // v2.9.139：启动带参数 + 定位模拟
        register(AppLaunchOptionsTool())
        register(LocationFakeTool())
        register(LocationFakeStatusTool())
        register(LocationFakeClearTool())
        // v2.9.141：跨 App 数据桥（沙箱破坏者）+ AI 操作宏录制/回放
        register(BridgeContainerTool())
        register(BridgeLsTool())
        register(BridgeReadTool())
        register(BridgeCopyTool())
        register(BridgeExportTool())
        register(BridgeImportTool())
        register(DebugDumpConversationsTool())
        register(DebugDumpConversationTool())
        register(ChatSendTool())
        register(ChatReplyTool())
        register(ModelListTool())
        register(ModelSwitchTool())
        register(DebugDumpModelConfigsTool())
        register(DebugDumpNetworkLogTool())
        register(MacroRecordTool())
        register(MacroStopTool())
        register(MacroListTool())
        register(MacroRunTool())
        register(MacroDeleteTool())
        register(MacroExportTool())

        // v3.0.67：toolchain 工具
        register(ToolchainStatusTool())
        register(ToolchainInstallTool())
        register(ToolchainUninstallTool())
        // v3.0.71：AI 自我进化——加载外部 dylib 注册新工具
        register(ToolLoadDylibTool())
        // v3.0.72：语义化 UI 操作 + OCR
        register(ControlTapTextTool())
        register(ControlTypeTextTool())
        register(OCRImageTool())

        AuditLog.shared.log("core", detail: "已注册 \(definitions.count) 个工具")
    }
}

// MARK: - tool_search 元工具（v2.9.16 渐进式披露）

/// 模型用此工具按关键词搜索全部可用工具，返回名称+摘要清单。
/// 命中后 App 会把对应工具的完整 schema 注入下一轮请求，从而
/// 不必把 80+ 工具全量塞进每次请求（学 OpenClaw / OpenAI Tool Search）。
final class ToolSearchTool: MCPTool {
    // v3.1.8：tool_search 调用计数——告诉 AI 已经搜了几次
    static var searchCount: Int = 0
    let definition = ToolDefinition(
        name: "tool_search",
        summary: "Search for tools. Use for: you need a tool but don't know its exact name. First call returns ALL tools (name + one-line desc) so you can see everything at once. Subsequent calls search by keyword. Don't use for: you already know the tool name (call it directly). Example: user says '帮我抓包' → first call shows all tools → find network.capture.",
        parameters: ["query": "Search keyword (e.g. '抓包', 'injection', 'file')", "limit": "Max results (default 8)"], verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let query = (params["query"] as? String) ?? ""
        let limit = (params["limit"] as? NSNumber)?.intValue ?? 0
        ToolSearchTool.searchCount += 1
        
        // v3.1.20: 第一次调用 tool_search 时，返回全部工具名+一句话介绍
        // AI 一次看完全部，不用反复搜
        // v3.1.24: 改成返回全部工具（不管什么模式），不是只返回 enabledDefinitions
        // v3.1.25: 第一次调用只返回简短描述（第一句话），不返回完整 Use for/Don't use for
        //          避免 210 个工具太长导致 AI 陷入死循环
        var hits: [[String: String]]
        if ToolSearchTool.searchCount == 1 {
            // 第一次：返回全部工具（不管什么模式都全量加载），但只返回简短描述
            let allTools = ToolRegistry.shared.definitions
            hits = allTools.map { def in
                // 截取 summary 的第一句话（到第一个 . 或 \n 为止）
                let shortSummary: String
                if let range = def.summary.range(of: ". ") {
                    shortSummary = String(def.summary[..<range.lowerBound]) + "."
                } else if let newlineRange = def.summary.range(of: "\n") {
                    shortSummary = String(def.summary[..<newlineRange.lowerBound])
                } else {
                    shortSummary = def.summary
                }
                return ["name": def.name, "summary": shortSummary]
            }
        } else {
            // 之后：按关键词搜索，返回完整描述
            hits = ToolRegistry.shared.searchTools(query: query, limit: limit)
        }
        // v3.1.9: 不自动授权全部搜到的工具——按需加载，AI 实际调用时才授权
        // 这样只加载要用的那个工具的完整 schema，不加载全部
        // for h in hits {
        //     guard let n = h["name"], !n.isEmpty else { continue }
        //     ToolRegistry.shared.approveForSession(n)
        // }
        // v2.9.167：按用户示例最紧凑形态——无 hint/无 query、authorized 保留（明确可直调）、
        // summary 改 desc 短摘要（30 字足够 AI 判断用途）、_noMessage 省顶层 message。
        // 单次搜索比 v2.9.165 再省 ~40 token，且信息不减。
        // v3.0.95：加 hint 明确告诉 AI "这些工具你现在就可以调用了"
        let totalTools = ToolRegistry.shared.toolCount
        let approvedCount = ToolRegistry.shared.approvedToolNames().count
        var hint = "✅ These tools are now authorized and ready to call directly."
        hint += "\n🔍 Search #\(ToolSearchTool.searchCount) | 📊 Total: \(totalTools) tools | \(approvedCount) approved | \(totalTools - approvedCount) remaining."
        if ToolSearchTool.searchCount >= 3 {
            hint += "\n⚠️ You've searched \(ToolSearchTool.searchCount) times. Stop searching and use what you have. If you can't find the right tool, tell the user what you can do."
        }
        if hits.isEmpty {
            hint += "\n⚠️ No new tools found for '\(query)'."
        }
        // v3.1.20: 第一次调用显示全部工具，之后只显示前 5 个
        let showCount = (ToolSearchTool.searchCount == 1) ? hits.count : min(5, hits.count)
        for h in hits.prefix(showCount) {
            if let n = h["name"], let s = h["summary"] {
                hint += "\n  - \(n): \(s)"
            }
        }
        if hits.count > showCount {
            hint += "\n  ... and \(hits.count - showCount) more"
        }
        return [
            "_noMessage": true,
            "total": hits.count,
            "authorized": hits.map { $0["name"] ?? "" },
            "hint": hint,
            "tools": hits.map { h -> [String: String] in
                var d = h
                if let s = d["summary"] {
                    // v3.1.22: 去掉截断，返回完整描述，AI 能准确理解工具用途
                    d["desc"] = s
                    d.removeValue(forKey: "summary")
                }
                return d
            }
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

    /// v2.9.62：把 App bundle 内 Resources/tweaks/ 下的内置 dylib 复制到工作区 tweaks/ 目录
    /// AI 可通过 artifact.find 直接定位，无需用户手动传输
    public static func ensureBundledTweaks() {
        guard let tweaksDir = Bundle.main.url(forResource: "tweaks", withExtension: nil) else { return }
        let destDir = root.appendingPathComponent("tweaks", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: tweaksDir, includingPropertiesForKeys: nil) else { return }
        for src in files {
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }
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

// MARK: - v3.0.71：外部 dylib 工具注册（AI 自我进化）

/// 外部工具包装：把 dylib 的 handler 包装成 MCPTool
public final class ExternalMCPTool: MCPTool {
    public let definition: ToolDefinition
    private let handler: ([String: Any]) throws -> [String: Any]

    public init(definition: ToolDefinition, handler: @escaping ([String: Any]) throws -> [String: Any]) {
        self.definition = definition
        self.handler = handler
    }

    public func invoke(_ params: [String: Any]) throws -> [String: Any] {
        try handler(params)
    }
}

/// C 函数签名：让外部 dylib 能注册工具
/// dylib 加载后调用 TARegisterTool(name, summary, paramsJSON, handler)
/// handler 是 C 函数指针：NSDictionary* (^)(NSDictionary*)
typealias TAExternalHandler = @convention(block) (NSDictionary) -> NSDictionary

/// 全局注册函数——dylib 里调这个
@_cdecl("TARegisterTool")
public func TARegisterTool(_ name: UnsafePointer<CChar>,
                           _ summary: UnsafePointer<CChar>,
                           _ paramsJSON: UnsafePointer<CChar>,
                           _ handler: @escaping @convention(block) (NSDictionary) -> NSDictionary) {
    let n = String(cString: name)
    let s = String(cString: summary)
    let p = String(cString: paramsJSON)

    // 解析 params JSON
    var params: [String: String] = [:]
    if let data = p.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        params = obj
    }

    let def = ToolDefinition(name: n, summary: s, parameters: params, verified: true, category: "external")
    ToolRegistry.shared.registerExternalTool(def) { params in
        let result = handler(params as NSDictionary)
        // NSDictionary → [String: Any]
        var dict: [String: Any] = [:]
        for (k, v) in result {
            if let key = k as? String { dict[key] = v }
        }
        return dict
    }
}
