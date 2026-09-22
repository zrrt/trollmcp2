import Foundation

// v2.9.37：内置浏览器 MCP 工具（AI 可控）
// 流程：browser.open 打开 → browser.wait 等待加载 → browser.snapshot 获取可交互元素（蓝框编号 idx）
//      → browser.click(idx) / browser.type(idx, text) / browser.submit(idx) 提交
//      → browser.text 读取页面正文 → browser.scroll 翻页 → browser.eval 执行任意 JS
// v2.9.88：新增 wait/text/scroll/submit；工具描述带完整工作流引导，AI 不会再"只查状态不打开"。

struct BrowserStatusTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.status",
        summary: "Check if the built-in browser is open. Use for: see if browser is available before using other browser tools. Don't use for: open browser (use browser.open/browser.navigate), close browser. Example: user says '浏览器开了吗' → check browser status.",
        parameters: [:],
        verified: true, category: "browser")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        AuditLog.shared.log("browser.status", detail: "status")
        return BrowserManager.shared.status()
    }
}

struct BrowserOpenTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.open",
        summary: "Open the built-in browser and navigate to a URL. Use for: open a website, start browsing. Don't use for: control native iPhone apps (use control.*), read page content (use browser.text after open). Example: user says '打开百度' → open https://www.baidu.com.",
        parameters: ["url": "Website URL to open (e.g. https://www.baidu.com)"],
    verified: true, category: "browser")
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
        summary: "Wait for the web page to finish loading. Use for: after navigating, wait for page to load before doing actions. Don't use for: just open URL (use browser.navigate), scroll page (use browser.scroll). Example: user says '打开百度，等加载完' → navigate then wait.",
    verified: true, category: "browser")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let timeout = params["timeout"] as? Int ?? 15
        let r = BrowserManager.shared.wait(timeout: timeout)
        AuditLog.shared.log("browser.wait", detail: "loaded=\(r["loaded"] ?? false)")
        // v3.1.8：返回更明确的错误信息，而不是"未知错误"
        if !(r["ok"] as? Bool ?? true) {
            return r
        }
        return r
    }
}

struct BrowserTextTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.text",
        summary: "Read text content of current web page. Use for: read what's on a webpage, extract article text, search within page. Don't use for: open new URL (use browser.navigate), inspect page HTML/structure (use browser.snapshot), type into input box (use browser.type), click buttons (use browser.eval). Example: user says '百度搜了什么' → read current page text.",
        parameters: ["max_chars": "Max characters to return (default 3000)", "query": "Optional: only return text containing this keyword (e.g. '价格')"],
    verified: true, category: "browser")
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
        summary: "Scroll the current web page up/down. Use for: read more content on a long webpage, navigate within page. Don't use for: open new URL (use browser.navigate), scroll native app (use control.swipe). Example: user says '往下翻' → scroll down.",
        parameters: ["direction": "Scroll direction: down / up / top (go to top) / bottom (go to end)"],
    verified: true, category: "browser")
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
        summary: "Submit a web form (click submit button). Use for: submit a filled-in form on a webpage. Don't use for: fill form fields (use browser.fill_form), click random button (use browser.eval). Prerequisite: first use browser.snapshot to get element idx. Example: user says '提交搜索' → submit form.",
        parameters: ["idx": "Element index from snapshot"]
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

struct BrowserFormFieldsTool: MCPTool {
    var definition = ToolDefinition(
        name: "browser.form_fields",
        summary: "List all form fields on the current web page. Use for: see what input fields exist on a webpage before filling them. Don't use for: fill the form (use browser.fill_form), just read text (use browser.text). Example: user says '这个登录页有哪些输入框' → list form fields.",
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
        summary: "Auto-fill a web form (fill multiple fields at once). Use for: login form, search form, any form with multiple inputs. Don't use for: type into single field (use browser.type), click button (use browser.click). Example: user says '自动登录，用户名 admin 密码 123' → fill form with multiple fields.",
        parameters: ["values": "Map of field name → value (e.g. {\"用户名\":\"admin\",\"密码\":\"123\"})", "submit": "Auto-submit after filling (default false)"], verified: true)
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
        summary: "Wait for a specific element to appear on the page. Use for: after clicking a button, wait for result to load. Don't use for: wait for whole page to load (use browser.wait), scroll page (use browser.scroll). Example: user says '点搜索后等结果出来' → wait for results element.",
        parameters: ["selector": "CSS selector of element to wait for", "text": "Wait for element containing this text", "timeout": "Max wait seconds (default 15)"], verified: true)
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
        summary: "Inspect web page HTML structure / find buttons/inputs. Use for: find specific element on page, debug why click didn't work, see what clickable elements exist. Don't use for: just reading text (use browser.text, simpler), open new URL (use browser.navigate). Example: user says '页面上有什么按钮' → snapshot and list clickable elements.",
        parameters: ["query": "Filter keyword (optional: only return elements matching this text/tag/name. e.g. '搜索' / '登录' / 'button')"],
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
        summary: "Click a web page element (button/link). Use for: click buttons, links on a webpage. Don't use for: submit form (use browser.submit), type text (use browser.type). Prerequisite: first use browser.snapshot to get element idx. Example: user says '点这个登录按钮' → click element.",
        parameters: ["idx": "Element index from snapshot"]
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
        summary: "Type text into an input field on the web page. Use for: type into search box, fill form field on a website. Don't use for: type into native app (use control.type_text), click a button (use browser.eval). Prerequisite: first call browser.snapshot to find the input element's idx. Example: type 'iPhone 15' into search box.",
        parameters: ["idx": "Element index from browser.snapshot result (integer, required)", "text": "Text to type into the input field (required)"], verified: true)
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
        summary: "Run custom JavaScript code in the web page. Use for: advanced page manipulation, extract data, automate complex actions. Don't use for: simple click/type (use browser.click/type), read text (use browser.text). Example: user says '用 JS 提取页面所有链接' → eval JS.",
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
        summary: "Navigate browser to URL. Use for: open web pages, change browser page. Don't use for: control native apps (use control.*), file operations (use fs.*), app management (use app.*).",
        parameters: ["url": "URL to open (optional). e.g. https://www.baidu.com", "action": "back/forward/reload (optional)"],
    verified: true, category: "browser")
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
