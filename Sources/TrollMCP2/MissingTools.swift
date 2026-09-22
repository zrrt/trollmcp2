import Foundation
import UIKit
import EventKit
import UserNotifications

// MARK: - 日历：创建事件

final class CalendarCreateEventTool: MCPTool {
    let definition = ToolDefinition(name: "calendar.create_event",
        summary: "Create a new calendar event (meeting/appointment). Use for: schedule a meeting, add event to iPhone Calendar. Don't use for: list upcoming events (use calendar.list), create reminder (use reminder.create). Example: user says '明天下午3点加个会议' → create calendar event.",
        parameters: ["title": "Event title (e.g. 'Team Meeting')", "start": "Start time (ISO8601 format)", "end": "End time (optional, default +1 hour)", "notes": "Optional notes for the event"], verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        guard let startStr = params["start"] as? String,
              let start = ISO8601DateFormatter().date(from: startStr) else {
            throw MCPError.invalidParams("start 需为 ISO8601")
        }
        let end = (params["end"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? Calendar.current.date(byAdding: .hour, value: 1, to: start)!

        var result: [String: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let store = EKEventStore()
            store.requestAccess(to: .event) { granted, err in
                defer { sem.signal() }
                guard granted else {
                    result = ["created": false, "error": "日历未授权: \(err?.localizedDescription ?? "")"]
                    return
                }
                let ev = EKEvent(eventStore: store)
                ev.title = title
                ev.startDate = start
                ev.endDate = end
                ev.notes = params["notes"] as? String
                do {
                    try store.save(ev, span: .thisEvent, commit: true)
                    result = ["created": true, "title": title, "start": startStr,
                              "eventIdentifier": ev.eventIdentifier ?? ""]
                } catch {
                    result = ["created": false, "error": error.localizedDescription]
                }
            }
        }
        sem.wait()
        AuditLog.shared.log("calendar.create_event", detail: title)
        return result
    }
}

// MARK: - 提醒：定时提醒（真实本地通知）

final class ReminderScheduleTool: MCPTool {
    let definition = ToolDefinition(name: "reminder.schedule",
        summary: "Schedule a one-time local notification reminder. Use for: get reminded after a delay, alert user when task completes. Don't use for: recurring reminder (use reminder.repeating), create calendar event (use calendar.create_event). Example: user says '10分钟后提醒我喝水' → schedule reminder.",
        parameters: ["title": "Notification title", "body": "Notification message", "delay_seconds": "Delay before notification (seconds)"],
        verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        let delay = max(params["delay_seconds"] as? Int ?? 60, 1)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = params["body"] as? String ?? ""
        content.sound = .default
        let id = UUID().uuidString
        let req = UNNotificationRequest(identifier: id,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        AuditLog.shared.log("reminder.schedule", detail: "\(title) +\(delay)s")
        return ["scheduled": true, "id": id, "fire_in_seconds": delay]
    }
}

final class ReminderScheduleRecurringTool: MCPTool {
    let definition = ToolDefinition(name: "reminder.schedule_recurring",
        summary: "Schedule a repeating reminder. Use for: periodic alerts (hourly/daily/etc). Don't use for: one-time reminder (use reminder.schedule), create calendar event (use calendar.create_event). Example: user says '每小时提醒我喝水' → recurring reminder.",
        parameters: ["title": "Reminder title", "body": "Reminder content", "interval_seconds": "Repeat interval in seconds"], verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        let interval = max(params["interval_seconds"] as? Int ?? 3600, 1)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = params["body"] as? String ?? ""
        content.sound = .default
        let id = UUID().uuidString
        let req = UNNotificationRequest(identifier: id,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(interval), repeats: true))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        AuditLog.shared.log("reminder.schedule_recurring", detail: "\(title) every \(interval)s")
        return ["scheduled": true, "id": id, "interval_seconds": interval]
    }
}

// MARK: - 设备快照（电池/存储/系统）

final class DeviceSnapshotTool: MCPTool {
    let definition = ToolDefinition(name: "device.snapshot", summary: "Quick device status snapshot: battery level, memory usage, disk space, iOS version. Use for: check device health, see how much free space, monitor performance. Don't use for: detailed device info (use device.info), spoof device info (use device.fake). Example: user says '手机内存还剩多少' → device snapshot.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryLevel
        let fm = FileManager.default
        var freeBytes: Int64 = 0
        if let url = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            freeBytes = Int64(vals?.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        return [
            "model": UIDevice.current.model,
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "batteryLevel": battery >= 0 ? String(format: "%.0f%%", battery * 100) : "unknown",
            "freeStorageBytes": freeBytes,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}

// MARK: - 网络搜索（v2.9.79：Bing 主引擎 + DuckDuckGo 免 key fallback，对齐 OpenClaw/Hermes 设计）

final class WebSearchTool: MCPTool {
    let definition = ToolDefinition(name: "web.search",
        summary: "Search the web (Google/Bing). Use for: find information online, look up facts, search for tutorials/docs. Don't use for: open a specific website (use browser.open), search saved knowledge (use knowledge.search). Example: user says 'iPhone 16 什么时候发布' → search web.",
        parameters: ["query": "Search keywords (e.g. 'iOS 17 jailbreak guide')", "limit": "Max results (default 8)"], verified: true, category: "browser")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let query = params["query"] as? String, !query.isEmpty else {
            throw MCPError.invalidParams("query required")
        }
        let limit = params["limit"] as? Int ?? 8
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        // 1) Bing 主引擎
        let bingResults = fetchBing(query: q, limit: limit)
        if !bingResults.isEmpty {
            AuditLog.shared.log("web.search", detail: "\(query) → Bing \(bingResults.count) 条")
            return ["query": query, "engine": "Bing", "count": bingResults.count, "results": bingResults]
        }
        // 2) DuckDuckGo 免 key fallback
        let ddgResults = fetchDuckDuckGo(query: q, limit: limit)
        AuditLog.shared.log("web.search", detail: "\(query) → DuckDuckGo \(ddgResults.count) 条（Bing 无结果时回退）")
        return ["query": query, "engine": ddgResults.isEmpty ? "none" : "DuckDuckGo", "count": ddgResults.count, "results": ddgResults]
    }

    private func fetchBing(query: String, limit: Int) -> [[String: String]] {
        guard let url = URL(string: "https://www.bing.com/search?q=\(query)") else { return [] }
        guard let html = fetchHTML(url) else { return [] }
        return parseBing(html: html, limit: limit)
    }

    private func fetchDuckDuckGo(query: String, limit: Int) -> [[String: String]] {
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(query)") else { return [] }
        guard let html = fetchHTML(url) else { return [] }
        return parseDuckDuckGo(html: html, limit: limit)
    }

    /// 同步抓取网页（15 秒超时）
    /// v2.9.129：UA 改桌面 Chrome —— Bing 移动版 HTML 结构与桌面版不同且不稳定，
    /// 桌面版 b_algo 结构多年稳定，解析命中率高
    private func fetchHTML(_ url: URL) -> String? {
        var html: String?
        var fetchError: String?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.dataTask(with: req) { data, _, err in
                defer { sem.signal() }
                if let err = err { fetchError = err.localizedDescription; return }
                html = String(data: data ?? Data(), encoding: .utf8)
            }
            task.resume()
        }
        sem.wait()
        if let e = fetchError {
            AuditLog.shared.log("web.search", detail: "fetch failed: \(e)")
        }
        return html
    }

    /// v2.9.129：Bing 解析增强——三级兜底，不再"只出一条"
    /// 1) 严格 b_algo 块  2) 宽松 b_algo 块(class 带附加项)  3) 通用 h2>a 兜底
    private func parseBing(html: String, limit: Int) -> [[String: String]] {
        var out = parseBingBlocks(html: html, pattern: "<li class=\"b_algo\">(.*?)</li>", limit: limit)
        if out.count < limit {
            out += parseBingBlocks(html: html, pattern: "<li class=\"b_algo[^\"]*\">(.*?)</li>", limit: limit - out.count)
        }
        if out.isEmpty {
            out = parseBingGeneric(html: html, limit: limit)
        }
        return out
    }

    private func parseBingBlocks(html: String, pattern: String, limit: Int) -> [[String: String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [[String: String]] = []
        for m in matches {
            let block = ns.substring(with: m.range(at: 1))
            // 标题：<h2> 下第一个 <a>，容许多行/嵌套 span
            let head = block.firstMatch(pattern: "<h2[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>")
            // 摘要：取 b_caption 或第一个 <p>（去除标签）
            let snippet = (block.firstCapture(pattern: "<p[^>]*>([\\s\\S]*?)</p>") ?? "").stripHTMLTags()
            if let caps = head, caps.count == 2 {
                let title = caps[1].stripHTMLTags()
                if !title.isEmpty {
                    out.append(["title": title, "url": caps[0], "snippet": snippet])
                }
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// 通用兜底：任意 <h2><a href="...">标题</a></h2>（Bing 改版时仍能出结果）
    private func parseBingGeneric(html: String, limit: Int) -> [[String: String]] {
        guard let regex = try? NSRegularExpression(pattern: "<h2[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>[\\s\\S]*?</h2>", options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [[String: String]] = []
        var seen = Set<String>()
        for m in matches {
            let url = ns.substring(with: m.range(at: 1))
            let title = ns.substring(with: m.range(at: 2)).stripHTMLTags()
            guard !title.isEmpty, !url.hasPrefix("javascript:"), seen.insert(url).inserted else { continue }
            out.append(["title": title, "url": url, "snippet": ""])
            if out.count >= limit { break }
        }
        return out
    }

    private func parseDuckDuckGo(html: String, limit: Int) -> [[String: String]] {
        guard let re = try? NSRegularExpression(pattern: "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [[String: String]] = []
        for m in matches.prefix(limit) {
            let url = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            let title = ns.substring(with: m.range(at: 2)).stripHTMLTags()
            if url.hasPrefix("//") { continue }
            // 摘要（紧随其后的 result__snippet）
            let snipRange = NSRange(location: m.range.location, length: min(ns.length - m.range.location, 600))
            let snipBlock = ns.substring(with: snipRange)
            let snippet = snipBlock.firstCapture(pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>")?.stripHTMLTags() ?? ""
            if !title.isEmpty {
                out.append(["title": title, "url": url, "snippet": snippet])
            }
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - 网页抓取（web.fetch，对齐 OpenClaw web_fetch 设计：搜索结果 → 抓原文）

final class WebFetchTool: MCPTool {
    let definition = ToolDefinition(name: "web.fetch",
        summary: "Fetch and read text content from a web page URL. Use for: read an article/webpage without opening browser, scrape page text. Don't use for: search web (use web.search), interact with page (use browser.open). Example: user says '读一下这个网页的内容' → fetch web page.",
        parameters: ["url": "Web page URL to read", "maxChars": "Max characters to return (default 4000)"], verified: true, category: "browser")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
            throw MCPError.invalidParams("url required")
        }
        let maxChars = params["maxChars"] as? Int ?? 4000
        var html: String?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.dataTask(with: req) { data, _, err in
                defer { sem.signal() }
                guard err == nil, let data = data else { return }
                html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)?.description
            }
            task.resume()
        }
        sem.wait()
        
        // v3.1.21: web.fetch 失败自动 fallback 到内置浏览器
        // AI 根本不需要知道这个逻辑，直接调用 web.fetch 就能得到结果
        if html == nil {
            AuditLog.shared.log("web.fetch", detail: "直接 fetch 失败，fallback 到内置浏览器: \(urlString)")
            do {
                // 1. 用内置浏览器打开网页
                if let navTool = ToolRegistry.shared.tool(named: "browser.navigate") {
                    _ = try navTool.invoke(["url": urlString])
                }
                // 2. 等 2 秒加载
                Thread.sleep(forTimeInterval: 2.0)
                // 3. 读取网页内容
                if let textTool = ToolRegistry.shared.tool(named: "browser.text") {
                    let result = try textTool.invoke([:])
                    if let text = result["text"] as? String, !text.isEmpty {
                        AuditLog.shared.log("web.fetch", detail: "fallback 成功: \(urlString) → \(text.count) chars")
                        return [
                            "url": urlString,
                            "title": result["title"] as? String ?? "",
                            "text": String(text.prefix(maxChars)),
                            "fallback_used": true,
                            "note": "Direct fetch failed, used built-in browser as fallback"
                        ]
                    }
                }
            } catch {
                AuditLog.shared.log("web.fetch", detail: "fallback 也失败: \(error.localizedDescription)")
            }
        }
        
        guard let raw = html else {
            throw MCPError.failed("fetch failed: \(urlString) (direct fetch and browser fallback both failed)")
        }
        // 提取标题 + 正文纯文本
        let title = raw.firstCapture(pattern: "<title[^>]*>(.*?)</title>")?.stripHTMLTags() ?? ""
        var text = stripHTML(raw)
        if !text.isEmpty {
            text = String(text.prefix(maxChars))
        }
        AuditLog.shared.log("web.fetch", detail: "\(urlString) → \(text.count) chars")
        return ["url": urlString, "title": title, "text": text]
    }

    /// HTML → 纯文本（去 script/style/标签，压缩空白）
    private func stripHTML(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    /// 返回所有捕获组（不含整串）
    fileprivate func firstMatch(pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)) else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            groups.append((self as NSString).substring(with: m.range(at: i)))
        }
        return groups
    }

    /// 返回第一个捕获组
    fileprivate func firstCapture(pattern: String) -> String? {
        firstMatch(pattern: pattern)?.first
    }

    /// v2.9.79：去除 HTML 标签与常见实体，用于搜索标题/摘要清洗
    fileprivate func stripHTMLTags() -> String {
        var s = self
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 本机知识库（文件存储）

final class KnowledgeStore {
    static let shared = KnowledgeStore()
    var dir: URL { Workspace.root.appendingPathComponent("knowledge", isDirectory: true) }
    func ensure() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func list() -> [String] {
        ensure()
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// v2.9.138：自动会话记忆（类 code-session-memory）——AI 每完成一轮文字回复，
    /// 把「用户提问 + AI 结论 + 涉及工具」追加到 knowledge/session_memory.md，
    /// 供后续会话用 knowledge.search（BM25）检索。行数上限 300，自动滚动。
    func appendSessionMemory(user: String, reply: String, tools: [String]) {
        ensure()
        let url = dir.appendingPathComponent("session_memory.md")
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        var entry = "- \(formatter.string(from: Date())) 问: \(user)"
        if !reply.isEmpty { entry += " → AI: \(reply)" }
        if !tools.isEmpty { entry += " [工具: \(tools.joined(separator: "、"))]" }
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: .newlines) ?? []
        lines.append(entry)
        if lines.count > 300 { lines = Array(lines.suffix(300)) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// v2.9.138：BM25 本地加权检索（零依赖，中英混合分词）
    /// 返回按相关性排序的命中行；无命中返回空数组（调用方回退 contains）
    func bm25Search(query: String, limit: Int = 15) -> [(file: String, line: Int, snippet: String, score: Double)] {
        let qTokens = BM25Tokenizer.tokenize(query)
        guard !qTokens.isEmpty else { return [] }
        // 文档 = 行。一次扫描所有知识库文件构建索引（本地文件小，查询频率低）
        var docs: [(file: String, line: Int, text: String, tokens: [String])] = []
        var df: [String: Int] = [:]      // 含 token 的行数
        var totalLines = 0
        var totalTokens = 0
        for file in list() {
            let url = dir.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() {
                let toks = BM25Tokenizer.tokenize(line)
                guard !toks.isEmpty else { continue }
                docs.append((file, i + 1, line, toks))
                totalLines += 1
                totalTokens += toks.count
                for t in Set(toks) { df[t, default: 0] += 1 }
            }
        }
        guard !docs.isEmpty else { return [] }
        let avgdl = Double(totalTokens) / Double(totalLines)
        let N = Double(totalLines)
        let k1 = 1.5, b = 0.75
        // 查询 token 只取出现过的（避免全零）
        let querySet = Set(qTokens).filter { df[$0] != nil }
        guard !querySet.isEmpty else { return [] }
        // idf 预计算
        var idf: [String: Double] = [:]
        for t in querySet {
            let n = Double(df[t] ?? 0)
            idf[t] = log(1 + (N - n + 0.5) / (n + 0.5))
        }
        // 逐行打分
        var scored: [(file: String, line: Int, snippet: String, score: Double)] = []
        for d in docs {
            var score = 0.0
            let dl = Double(d.tokens.count)
            var tf: [String: Int] = [:]
            for t in d.tokens { tf[t, default: 0] += 1 }
            for t in querySet {
                let f = Double(tf[t] ?? 0)
                guard f > 0 else { continue }
                score += (idf[t] ?? 0) * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgdl))
            }
            if score > 0 {
                scored.append((d.file, d.line, d.text.trimmingCharacters(in: .whitespaces), score))
            }
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }
}

/// v2.9.137：BM25 分词器——ASCII 词 + 中文 bigram/单字，零依赖
enum BM25Tokenizer {
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        let ns = s as NSString
        if let ascii = try? NSRegularExpression(pattern: "[a-zA-Z0-9][a-zA-Z0-9_\\-]{1,}") {
            ascii.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let r = m?.range, r.location != -1 {
                    tokens.append(ns.substring(with: r).lowercased())
                }
            }
        }
        if let cjk = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fff]+") {
            cjk.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let r = m?.range, r.location != -1 else { return }
                let chars = Array(ns.substring(with: r))
                if chars.count == 1 {
                    tokens.append(String(chars[0]))
                }
                for i in 0..<(chars.count - 1) {
                    tokens.append(String(chars[i]) + String(chars[i + 1]))
                }
                for c in chars { tokens.append(String(c)) }
            }
        }
        return tokens
    }
}

final class KnowledgeImportTextTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.import_text",
        summary: "Save text content to the knowledge base. Use for: store notes/reference material for later retrieval. Don't use for: write file to workspace (use fs.write), search saved knowledge (use knowledge.search). Example: user says '把这段笔记存下来' → import to knowledge base.",
        parameters: ["name": "Entry name/title", "content": "Text content to save"], verified: true, category: "knowledge")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, let content = params["content"] as? String else {
            throw MCPError.invalidParams("name, content required")
        }
        KnowledgeStore.shared.ensure()
        let file = KnowledgeStore.shared.dir.appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        AuditLog.shared.log("knowledge.import_text", detail: name)
        return ["imported": true, "name": file.lastPathComponent, "bytes": content.utf8.count]
    }
}

final class KnowledgeImportFileTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.import_file",
        summary: "Import a file into the knowledge base. Use for: store documents for later search/retrieval. Don't use for: import text content directly (use knowledge.import_text), search knowledge (use knowledge.search). Example: user says '把这个 PDF 存到知识库' → import file.",
        parameters: ["path": "File path (workspace-relative)", "name": "Entry name (optional)"], verified: true, category: "knowledge")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else { throw MCPError.invalidParams("path required") }
        let src = try Workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: src.path) else { throw MCPError.failed("not found: \(path)") }
        KnowledgeStore.shared.ensure()
        let name = params["name"] as? String ?? src.lastPathComponent
        let dst = KnowledgeStore.shared.dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        AuditLog.shared.log("knowledge.import_file", detail: name)
        return ["imported": true, "name": name]
    }
}

final class KnowledgeSearchTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.search",
        summary: "Search the knowledge base (saved documents/notes). Use for: find information you previously saved, search through imported documents. Don't use for: search the web (use web.search), search contacts (use contacts.search). Example: user says '我之前存的那个文档在哪' → search knowledge base.",
        parameters: ["query": "Search query / keywords", "limit": "Max results to return (default 15, max 50)"], verified: true, category: "knowledge")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let query = params["query"] as? String, !query.isEmpty else { throw MCPError.invalidParams("query required") }
        KnowledgeStore.shared.ensure()
        let limit = min(max(params["limit"] as? Int ?? 15, 1), 50)
        // 主路径：BM25 加权检索
        let scored = KnowledgeStore.shared.bm25Search(query: query, limit: limit)
        if !scored.isEmpty {
            AuditLog.shared.log("knowledge.search", detail: "\(query) → BM25 \(scored.count) 条")
            return ["query": query, "engine": "bm25", "count": scored.count,
                    "hits": scored.map { ["file": $0.file, "line": $0.line, "snippet": $0.snippet, "score": Double(round($0.score * 1000) / 1000)] }]
        }
        // 回退：关键词 contains
        var hits: [[String: Any]] = []
        for file in KnowledgeStore.shared.list() {
            let url = KnowledgeStore.shared.dir.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(query) {
                hits.append(["file": file, "line": i + 1, "snippet": line.trimmingCharacters(in: .whitespaces)])
                if hits.count >= limit { break }
            }
        }
        AuditLog.shared.log("knowledge.search", detail: "\(query) → contains \(hits.count) 条")
        return ["query": query, "engine": "contains", "count": hits.count, "hits": hits]
    }
}

final class KnowledgeDeleteTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.delete", summary: "Delete an entry from knowledge base. Use for: remove outdated info you saved before. Don't use for: search knowledge (use knowledge.search), save new knowledge (use knowledge.import_text). Warning: irreversible! Example: user says '删掉之前存的那个笔记' → delete knowledge entry.",
        parameters: ["name": "Entry name to delete"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let file = KnowledgeStore.shared.dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw MCPError.failed("not found: \(name)") }
        try FileManager.default.removeItem(at: file)
        AuditLog.shared.log("knowledge.delete", detail: name)
        return ["deleted": true, "name": name]
    }
}

// MARK: - 电话

final class PhoneCallTool: MCPTool {
    let definition = ToolDefinition(name: "phone.call", summary: "Open the phone dialer with a number pre-filled. Use for: initiate a phone call (opens dialer, user taps call). Don't use for: search contacts (use contacts.search), send message. Example: user says '打个电话给张三' → open dialer with his number.",
        parameters: ["number": "Phone number to dial (e.g. 13800138000)"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let number = params["number"] as? String, !number.isEmpty else { throw MCPError.invalidParams("number required") }
        // v3.0.42：修复号码被清空 bug——之前 components(separatedBy: 数字字符集) 把数字全当分隔符删了，
        // 返回空号码导致拨号器无反应。改为 filter 只保留数字和 +。
        let cleaned = String(number.filter { "+0123456789".contains($0) })
        guard !cleaned.isEmpty else { throw MCPError.invalidParams("number 无有效数字: \(number)") }
        // 用 telprompt:// 弹确认框，兼容性更好
        guard let url = URL(string: "telprompt://" + cleaned) else {
            throw MCPError.failed("URL 构造失败: \(number)")
        }
        var result: [String: Any] = ["number": cleaned]
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                result["opened"] = ok
                if !ok {
                    // 回退到 tel://
                    if let telURL = URL(string: "tel://" + cleaned) {
                        UIApplication.shared.open(telURL, options: [:]) { ok2 in
                            result["opened"] = ok2
                            result["fallback"] = "tel://"
                            sem.signal()
                        }
                    } else {
                        sem.signal()
                    }
                } else {
                    sem.signal()
                }
            }
        }
        _ = sem.wait(timeout: .now() + 5)
        AuditLog.shared.log("phone.call", detail: number)
        return result
    }
}

final class PhoneScheduleCallTool: MCPTool {
    let definition = ToolDefinition(name: "phone.schedule_call",
        summary: "Schedule a timed phone call reminder. Use for: get reminded to call someone after delay. Don't use for: actually make a call (not supported), create reminder (use reminder.schedule). Example: user says '5分钟后提醒我打电话给客户' → schedule call reminder.",
        parameters: ["number": "Phone number to call", "display_name": "Contact name (optional)", "delay_seconds": "Delay before reminder (seconds)"], verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let number = params["number"] as? String, !number.isEmpty else { throw MCPError.invalidParams("number required") }
        let delay = max(params["delay_seconds"] as? Int ?? 60, 1)
        let name = params["display_name"] as? String ?? number
        let content = UNMutableNotificationContent()
        content.title = "拨号提醒"
        content.body = "呼叫 \(name)（\(number)）"
        content.sound = .default
        let id = UUID().uuidString
        let req = UNNotificationRequest(identifier: id,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        AuditLog.shared.log("phone.schedule_call", detail: "\(name) +\(delay)s")
        return ["scheduled": true, "id": id, "number": number, "requiresUserTap": true]
    }
}

// MARK: - 技能开关

final class SkillsSetEnabledTool: MCPTool {
    let definition = ToolDefinition(name: "skills.set_enabled",
        summary: "Enable or disable a skill (prompt template). Use for: turn on/off specific skills so AI only sees relevant ones. Don't use for: list all skills (use skills.list), read skill instructions (use skills.read). Example: user says '关掉抓包那个技能' → disable it.",
        parameters: ["name": "Skill name", "enabled": "true (enable) or false (disable)"], verified: true, category: "skills")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let enabled = params["enabled"] as? Bool ?? true
        SkillStore.shared.setEnabled(name, enabled)
        return ["name": name, "enabled": enabled]
    }
}
