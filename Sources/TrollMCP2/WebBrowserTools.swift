import Foundation

// v2.9.37：内置浏览器 MCP 工具（AI 可控）
// 流程：browser.open 打开 → browser.snapshot 获取可交互元素（蓝框编号 idx）
//      → browser.click(idx) / browser.type(idx, text) → browser.eval 执行任意 JS
// 注意：调用前可用 browser.status 看当前 URL/标题。

struct BrowserStatusTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.status",
        summary: "查看内置浏览器状态：当前 URL、标题、高亮开关、元素数。AI 控制浏览器前先调用此工具了解当前页面。",
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
        summary: "在内置浏览器打开网页。参数 url：完整网址（如 https://example.com）。页面异步加载，稍后可 browser.snapshot 查看元素。",
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

struct BrowserSnapshotTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.snapshot",
        summary: "获取当前页面可交互元素快照：给每个按钮/链接/输入框加蓝色边框并编号（idx），返回 [{idx,tag,text,type,href,placeholder,value}]。可带 query 关键字按文本/标签/占位符过滤（如 query=\"登录\"），避免长页面全量返回。AI 按 idx 用 browser.click / browser.type 操作。",
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
