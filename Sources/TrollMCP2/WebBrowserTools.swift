import Foundation

// v2.9.37：内置浏览器 MCP 工具（AI 可控）
// 流程：browser.open 打开 → browser.wait 等待加载 → browser.snapshot 获取可交互元素（蓝框编号 idx）
//      → browser.click(idx) / browser.type(idx, text) / browser.submit(idx) 提交
//      → browser.text 读取页面正文 → browser.scroll 翻页 → browser.eval 执行任意 JS
// v2.9.88：新增 wait/text/scroll/submit；工具描述带完整工作流引导，AI 不会再"只查状态不打开"。

struct BrowserStatusTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.status",
        summary: "查看内置浏览器状态：当前 URL、标题、加载状态、元素数。注意：如果用户要求打开/访问某个网址，请直接调用 browser.open(url) 打开，不要只查状态。",
        parameters: [:]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        AuditLog.shared.log("browser.status", detail: "status")
        return BrowserManager.shared.status()
    }
}

struct BrowserOpenTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.open",
        summary: "在内置浏览器打开网页。参数 url：完整网址（如 https://example.com，可省略 https://）。页面异步加载，打开后必须调用 browser.wait 等待加载完成，再 browser.snapshot 获取可交互元素。",
        parameters: ["url": "string"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let url = params["url"] as? String else {
            throw MCPError.invalidParams("browser.open 需要 url 参数")
        }
        let msg = BrowserManager.shared.open(url)
        AuditLog.shared.log("browser.open", detail: url)
        return ["ok": true, "message": msg]
    }
}

struct BrowserWaitTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.wait",
        summary: "等待浏览器页面加载完成（最多 timeout 秒）。browser.open 后必须先调用本工具等加载完，否则 snapshot 拿不到元素。返回 URL、标题、页面正文长度。",
        parameters: ["timeout": "最多等待秒数（默认 15）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let timeout = params["timeout"] as? Int ?? 15
        let r = BrowserManager.shared.wait(timeout: timeout)
        AuditLog.shared.log("browser.wait", detail: "loaded=\(r["loaded"] ?? false)")
        return r
    }
}

struct BrowserTextTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.text",
        summary: "提取当前页面可见正文文本（最多 max_chars 字符）。用于 AI 阅读页面内容、验证操作结果（如登录后是否显示用户名、搜索结果是否出现）。可选 query 只返回关键词附近上下文。",
        parameters: ["max_chars": "最大字符数（默认 3000）", "query": "可选：只返回包含该关键词的上下文片段"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let maxChars = params["max_chars"] as? Int ?? 3000
        let query = params["query"] as? String
        let text = BrowserManager.shared.getText(maxChars: maxChars, query: query)
        AuditLog.shared.log("browser.text", detail: "len=\(text.count)")
        return ["ok": !text.hasPrefix("ERR:"), "text": text, "length": text.count]
    }
}

struct BrowserScrollTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.scroll",
        summary: "滚动当前页面：direction 取 down（下翻一屏）/ up（上翻）/ top（回到顶部）/ bottom（到底部）。滚动后元素编号会刷新，操作前重新 snapshot。",
        parameters: ["direction": "down/up/top/bottom"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let direction = params["direction"] as? String else {
            throw MCPError.invalidParams("browser.scroll 需要 direction 参数")
        }
        let msg = BrowserManager.shared.scroll(direction)
        AuditLog.shared.log("browser.scroll", detail: direction)
        return ["ok": !msg.hasPrefix("ERR"), "message": msg]
    }
}

struct BrowserSubmitTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.submit",
        summary: "在指定 idx 的输入框提交表单（idx 来自 browser.snapshot）。优先触发所在 form 的 submit，否则模拟回车。适合搜索框、登录表单、发送按钮。",
        parameters: ["idx": "integer"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let idx = params["idx"] as? Int ?? (params["idx"] as? String).flatMap({ Int($0) }) else {
            throw MCPError.invalidParams("browser.submit 需要整数 idx 参数")
        }
        let msg = BrowserManager.shared.submit(idx)
        AuditLog.shared.log("browser.submit", detail: "idx=\(idx) \(msg)")
        return ["ok": !msg.hasPrefix("ERR"), "message": msg]
    }
}

struct BrowserSnapshotTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.snapshot",
        summary: "获取当前页面可交互元素快照：给每个按钮/链接/输入框加蓝色边框并编号（idx），返回 [{idx,tag,text,type,href,placeholder,value}]。可带 query 关键字按文本/标签/占位符过滤（如 query=\"登录\"），避免长页面全量返回。AI 按 idx 用 browser.click / browser.type / browser.submit 操作。",
        parameters: ["query": "过滤关键字（按元素文本/标签/占位符/href/name 模糊匹配，可选，不带则返回前 20 个）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let q = params["query"] as? String
        let r = BrowserManager.shared.snapshot(query: q)
        AuditLog.shared.log("browser.snapshot", detail: "count=\(r["count"] ?? 0) query=\(q ?? "")")
        return r
    }
}

struct BrowserClickTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.click",
        summary: "点击页面上指定 idx 的元素（idx 来自 browser.snapshot 返回的编号，元素有蓝框）。参数 idx：整数。",
        parameters: ["idx": "integer"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let idx = params["idx"] as? Int ?? (params["idx"] as? String).flatMap({ Int($0) }) else {
            throw MCPError.invalidParams("browser.click 需要整数 idx 参数")
        }
        let msg = BrowserManager.shared.clickElement(idx)
        AuditLog.shared.log("browser.click", detail: "idx=\(idx) \(msg)")
        return ["ok": !msg.hasPrefix("ERR"), "message": msg]
    }
}

struct BrowserTypeTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.type",
        summary: "在指定 idx 的输入框填入文本（idx 来自 browser.snapshot）。参数 idx：整数；text：要输入的字符串。",
        parameters: ["idx": "integer", "text": "string"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let idx = params["idx"] as? Int ?? (params["idx"] as? String).flatMap({ Int($0) }) else {
            throw MCPError.invalidParams("browser.type 需要整数 idx 参数")
        }
        guard let text = params["text"] as? String else {
            throw MCPError.invalidParams("browser.type 需要 text 参数")
        }
        let msg = BrowserManager.shared.typeText(idx, text)
        AuditLog.shared.log("browser.type", detail: "idx=\(idx) len=\(text.count)")
        return ["ok": !msg.hasPrefix("ERR"), "message": msg]
    }
}

struct BrowserEvalTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.eval",
        summary: "在当前页面执行任意 JavaScript，返回结果字符串。高级操作（读取 DOM、提交表单、滚动等）。",
        parameters: ["js": "string"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let js = params["js"] as? String else {
            throw MCPError.invalidParams("browser.eval 需要 js 参数")
        }
        let r = BrowserManager.shared.evaluate(js)
        AuditLog.shared.log("browser.eval", detail: String(js.prefix(60)))
        return ["ok": !r.hasPrefix("ERR"), "result": r]
    }
}

struct BrowserNavigateTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.navigate",
        summary: "浏览器导航：action 取 back（后退）/ forward（前进）/ reload（刷新）。",
        parameters: ["action": "string"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("browser.navigate 需要 action 参数")
        }
        let msg: String
        switch action {
        case "back": msg = BrowserManager.shared.goBack()
        case "forward": msg = BrowserManager.shared.goForward()
        case "reload": msg = BrowserManager.shared.reload()
        default: throw MCPError.invalidParams("browser.navigate action 只支持 back/forward/reload")
        }
        AuditLog.shared.log("browser.navigate", detail: action)
        return ["ok": true, "message": msg]
    }
}
