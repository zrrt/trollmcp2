import Foundation

// v2.9.37：内置浏览器 MCP 工具（AI 可控）
// 流程：browser.open 打开 → browser.wait 等待加载 → browser.snapshot 获取可交互元素（蓝框编号 idx）
//      → browser.click(idx) / browser.type(idx, text) / browser.submit(idx) 提交
//      → browser.text 读取页面正文 → browser.scroll 翻页 → browser.eval 执行任意 JS
// v2.9.88：新增 wait/text/scroll/submit；工具描述带完整工作流引导，AI 不会再"只查状态不打开"。

struct BrowserStatusTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.status",
        summary: "Check browser status (open/closed). Use for: browser availability.",
        parameters: [:],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        AuditLog.shared.log("browser.status", detail: "status")
        return BrowserManager.shared.status()
    }
}

struct BrowserOpenTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.open",
        summary: "Open browser with URL. Use for: start web session.",
        parameters: ["url": "string"],
    verified: true)
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
        summary: "Wait for page load. Use for: sync with page.",
        parameters: ["timeout": "最多等待秒数（默认 15）"],
    verified: true)
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
        summary: "Get page text content. Use for: read web page.",
        parameters: ["max_chars": "最大字符数（默认 3000）", "query": "可选：只返回包含该关键词的上下文片段"],
    verified: true)
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
        summary: "Scroll page up/down. Use for: navigate page.",
        parameters: ["direction": "down/up/top/bottom"],
    verified: true)
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
        summary: "Submit form. Use for: send form data.",
        parameters: ["idx": "integer"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let idx = params["idx"] as? Int ?? (params["idx"] as? String).flatMap({ Int($0) }) else {
            throw MCPError.invalidParams("browser.submit 需要整数 idx 参数")
        }
        let msg = BrowserManager.shared.submit(idx)
        AuditLog.shared.log("browser.submit", detail: "idx=\(idx) \(msg)")
        return ["ok": !msg.hasPrefix("ERR"), "message": msg]
    }
}

struct BrowserFormFieldsTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.form_fields",
        summary: "List form fields on page. Use for: inspect form structure.",
        parameters: [:],
    verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let r = BrowserManager.shared.formFields()
        AuditLog.shared.log("browser.form_fields", detail: "count=\(r["count"] ?? 0)")
        return r
    }
}

struct BrowserFillFormTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.fill_form",
        summary: "Fill form fields. Use for: auto-fill web form."字段名或占位符或标签\":\"值\"}，自动匹配页面所有输入框/下拉框/勾选框（React/Vue 受控组件兼容）。下拉框传选项文字，勾选框传 true/false。需要精确指定时用 {\"__xpath\":\"元素xpath\",\"__value\":\"值\"}。填完可 submit=true 自动提交表单。适合登录/注册/搜索/下单填表。",
        parameters: ["values": "{\"字段\":\"值\"} 映射（必填）", "submit": "是否自动提交表单（默认 false）"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let values = params["values"] as? [String: String] else {
            throw MCPError.invalidParams("browser.fill_form 需要 values 参数，如 {\"用户名\":\"me\",\"密码\":\"xx\"}")
        }
        let submit = params["submit"] as? Bool ?? false
        let r = BrowserManager.shared.fillForm(values: values, submit: submit)
        AuditLog.shared.log("browser.fill_form", detail: "filled=\(r["filled"] ?? 0) missed=\(r["missed"] ?? [])")
        return r
    }
}

struct BrowserWaitForTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.wait_for",
        summary: "Wait for element to appear. Use for: sync with specific element."搜索结果\"）。用于 open 后等待结果页加载完成、登录后等待用户名出现。返回 found 是否出现。",
        parameters: ["selector": "CSS 选择器（与 text 二选一）", "text": "正文文本关键词（与 selector 二选一）", "timeout": "最多等待秒数（默认 15）"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let text = params["text"] as? String
        let selector = params["selector"] as? String
        let timeout = params["timeout"] as? Int ?? 15
        let r = BrowserManager.shared.waitFor(text: text, selector: selector, timeout: timeout)
        AuditLog.shared.log("browser.wait_for", detail: "found=\(r["found"] ?? false)")
        return r
    }
}

struct BrowserSnapshotTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.snapshot",
        summary: "Take browser snapshot (HTML/DOM). Use for: inspect page structure."登录\"），避免长页面全量返回。AI 按 idx 用 browser.click / browser.type / browser.submit 操作。",
        parameters: ["query": "过滤关键字（按元素文本/标签/占位符/href/name 模糊匹配，可选，不带则返回前 20 个）"],
    verified: true)
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
        summary: "Click element by selector. Use for: interact with page.",
        parameters: ["idx": "integer"], verified: true)
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
        summary: "Type text into element. Use for: input text.",
        parameters: ["idx": "integer", "text": "string"], verified: true)
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
        summary: "Evaluate JavaScript in page. Use for: run JS in browser.",
        parameters: ["js": "string"],
    verified: true)
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
        summary: "Navigate to URL. Use for: change page.",
        parameters: ["url": "string（可选）打开新网址", "action": "string（可选）back/forward/reload"],
    verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // v2.9.251: 兼容 url 参数——AI 常用 browser.navigate {url} 开网页,此前只认 action 导致"打开失败"
        if let url = params["url"] as? String, !url.isEmpty {
            let msg = BrowserManager.shared.open(url)
            AuditLog.shared.log("browser.navigate", detail: "url=\(url)")
            return ["ok": !msg.hasPrefix("ERR"), "message": msg, "used": "open"]
        }
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("browser.navigate 需要 url 或 action 参数")
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
