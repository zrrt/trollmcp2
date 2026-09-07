# -*- coding: utf-8 -*-
import io

# ============ 2. AdvancedTools.swift: AiAnalyzeTool 追加到文件尾部 ============
path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\AdvancedTools.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

tool = '''
// MARK: - v2.9.100 AI 分析引擎（Fuck 工具箱同款思路：采集 → LLM → 生成 hook 方案 → 应用）

/// ai.analyze_app — 采集目标 App ObjC 类结构，用当前配置的模型 LLM 分析出 hook 方案，
/// 自动写入 hook_config.json 并注入 ConfigHook 生效（methodLog 方法调用日志 + 可选 UI 配色）。
final class AiAnalyzeTool: MCPTool {
    let definition = ToolDefinition(
        name: "ai.analyze_app",
        summary: "AI 分析引擎（v2.9.100）：注入 ProbeAgent 采集目标 App 类结构 → 当前模型 LLM 分析生成 hook 方案（methodLog 方法日志 + UI 配色）→ 自动写 hook_config.json 并注入 ConfigHook 生效。适合 VIP / 去广告 / 绕过检测 / UI 定制方向",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "direction": "分析方向：vip / 去广告 / 绕过检测 / 全面 / 自定义（默认 全面）",
            "custom_hint": "direction=自定义 时的具体描述（如：找出会员判断逻辑）",
            "max_classes": "采集类上限（默认 80，最大 150；防 token 爆炸）",
            "prefix": "类名前缀过滤（可选，如 QQ，可大幅减少采集量）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \\(bundleId)", "hint": "用 injection.list 搜索"]
        }
        guard let cfg = ModelStore.shared.defaultConfig else {
            return ["error": "未配置模型", "hint": "先在 设置 → 模型 API 添加并选中模型"]
        }
        let direction = (params["direction"] as? String) ?? "全面"
        let customHint = params["custom_hint"] as? String ?? ""
        let maxClasses = min((params["max_classes"] as? Int) ?? 80, 150)
        let prefix = (params["prefix"] as? String) ?? ""
        let exeName = ProcessHelper.executableName(for: app)

        // 1) 确保 ProbeAgent 在目标进程里（复用 probe 注入逻辑）
        var probeInjected = false
        if let pid = ProcessHelper.pidOf(executableName: exeName) {
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 {
                probeInjected = true
            } else {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.runAsRoot("opainject", args: ["\\(pid)", dylib])
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        } else {
            let (launched, msg) = ProcessHelper.launchApp(bundleId: bundleId)
            if !launched { return ["error": msg, "hint": "手动打开目标 App 后重试"] }
            var pid: Int? = nil
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
            if let pid = pid {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.runAsRoot("opainject", args: ["\\(pid)", dylib])
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        }
        guard probeInjected else {
            return ["error": "ProbeAgent 注入失败（App 未运行或 opainject 失败）", "hint": "确认 App 在前台运行，或先手动打开"]
        }

        // 2) 采集类列表
        var clsPath = "/probe/classes?limit=\\(maxClasses)"
        if !prefix.isEmpty {
            let enc = prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prefix
            clsPath += "&prefix=\\(enc)"
        }
        var classes: [[String: Any]] = []
        if let (code, body) = httpGet(port: 4791, path: clsPath, timeout: 8), code == 200,
           let data = body.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            classes = Array(arr.prefix(maxClasses))
        }
        guard !classes.isEmpty else {
            return ["error": "采集类列表为空", "hint": "确认 App 运行中且 ProbeAgent 已注入（可先 probe.inspect bundle_id）"]
        }

        // 3) 构造 LLM 提示词
        let classSummary = classes.prefix(maxClasses).map {
            "\\($0["name"] as? String ?? "?")(\\($0["instanceMethodCount"] as? Int ?? 0))"
        }.joined(separator: ", ")
        let directionDesc = direction == "自定义" && !customHint.isEmpty ? customHint : direction
        let prompt = """
        你是资深 iOS 逆向工程师。目标 App 的 ObjC 运行时类列表（名称+实例方法数）：
        \\(classSummary)
        分析方向：\\(directionDesc)
        请从中挑选最值得 hook 的 3~8 个类，输出严格 JSON（不要 markdown 代码块）：
        {"methodLog":[{"class":"类名","selector":"方法名(含冒号)","note":"为什么 hook 它"}],"reason":"一句总体思路"}
        如果方向涉及 UI 定制，可附加 "navBarColor":"#RRGGBB"、"windowTint":"#RRGGBB" 字段。
        """
        var resultText = ""
        var errText = ""
        let sem = DispatchSemaphore(value: 0)
        ModelAPIClient.shared.sendChat(config: cfg, messages: [["role": "user", "content": prompt]]) { res in
            switch res {
            case .success(let t): resultText = t
            case .failure(let e): errText = e.localizedDescription
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 95)
        if !errText.isEmpty || resultText.isEmpty {
            return ["error": "AI 分析失败", "detail": errText.isEmpty ? "无返回" : errText,
                    "hint": "检查模型配置；如中转站对 /chat/completions 支持不佳，可在模型 API 里切换协议"]
        }

        // 4) 解析 JSON（剥掉可能的 ```json 围栏 / 前后杂文）
        var config: [String: Any] = ["reason": String(resultText.prefix(200))]
        if let open = resultText.range(of: "{"),
           let close = resultText.range(of: "}", options: .backwards) {
            let sub = String(resultText[open.lowerBound...close.upperBound])
            if let data = sub.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                config = obj
            }
        }
        if (config["methodLog"] as? [[String: Any]] ?? []).isEmpty {
            return ["error": "AI 未返回有效 methodLog", "ai_output": String(resultText.prefix(300))]
        }

        // 5) 应用（写入 hook_config.json + 注入 ConfigHook + 重启）
        let applied = try HookApplyTool().invoke(["bundle_id": bundleId, "config": config, "restart": true])
        return [
            "status": "analyzed_and_applied",
            "bundle_id": bundleId,
            "app": app.name,
            "direction": direction,
            "analyzed_classes": classes.count,
            "ai_output": String(resultText.prefix(400)),
            "hook_config": config,
            "applied": applied,
            "hint": "methodLog 日志会打印到目标 App 控制台；改配置后用 hook.apply 重发即可。恢复原始用 injection.disable"
        ]
    }
}
'''

if 'final class AiAnalyzeTool' not in c:
    c = c.rstrip() + '\n' + tool
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(c)
    print('APPENDED AiAnalyzeTool')
else:
    print('ALREADY EXISTS')

# ============ 3. MCPCore 注册 ============
path2 = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\MCPCore.swift'
with io.open(path2, 'r', encoding='utf-8') as f:
    c2 = f.read()

old = """        // v2.9.99：一键新机（绿盾式组合）
        register(NewDeviceTool())"""
new = """        // v2.9.99：一键新机（绿盾式组合）
        register(NewDeviceTool())
        // v2.9.100：AI 分析引擎
        register(AiAnalyzeTool())"""
assert old in c2, 'register anchor not found'
c2 = c2.replace(old, new)
with io.open(path2, 'w', encoding='utf-8') as f:
    f.write(c2)
print('REGISTERED AiAnalyzeTool')
