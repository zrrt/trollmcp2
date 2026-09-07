# -*- coding: utf-8 -*-
import io, re

# ============ 1. BrowserManager: UA 伪装 + webdriver 清除 ============
path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\BrowserManager.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

old = """    private func createWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        webView = wv
    }"""
new = """    private func createWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        // v2.9.98：UA 伪装成普通 iPhone Safari，减少被站点识别为应用内嵌/自动化浏览器
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1"
        wv.customUserAgent = ua
        // v2.9.98：隐藏自动化特征（webdriver），降低被检测为 AI/机器人控制的概率
        if let ucc = wv.configuration.userContentController as WKUserContentController? {
            let script = WKUserScript(source: "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});",
                                      injectionTime: .atDocumentStart, forMainFrameOnly: false)
            ucc.addUserScript(script)
        }
        webView = wv
    }"""
assert old in c, 'createWebView not found'
c = c.replace(old, new)

# open 的 URL 智能解析
old2 = """        var u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return "ERR: 空 URL" }
        if !u.contains("://") { u = "https://" + u }
        // 裸域名补 www（部分站点裸域 https 不响应，如 baidu.com → www.baidu.com）
        if let host = URL(string: u)?.host,
           host.split(separator: ".").count == 1 {
            u = u.replacingOccurrences(of: "https://\(host)", with: "https://www.\(host)")
        }"""
new2 = """        var u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return "ERR: 空 URL" }
        // v2.9.98：智能 URL 解析
        // 1) 已带协议 → 原样
        // 2) 纯 IP / localhost（含端口）→ http（内网服务一般不响应 https）
        // 3) 含空格、中文或没有点号 → Bing 搜索
        // 4) 其他 → https://
        if !u.contains("://") {
            let lower = u.lowercased()
            let isIP = lower.range(of: #"^(\d{1,3}\.){3}\d{1,3}(:\d+)?$"#, options: .regularExpression) != nil
            let isLocal = lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1")
            let hasSpaceOrCN = u.contains(" ") || u.range(of: #"[\\u4e00-\\u9fff]"#, options: .regularExpression) != nil
            let hasDot = u.contains(".")
            if isIP || isLocal {
                u = "http://" + u
            } else if hasSpaceOrCN || !hasDot {
                let q = u.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? u
                return "已在 Bing 搜索：\\(u)（非网址，按搜索处理）| https://www.bing.com/search?q=\\(q)"
            } else {
                u = "https://" + u
            }
        }
        // 裸域名补 www（部分站点裸域 https 不响应，如 example.com → www.example.com）
        if let host = URL(string: u)?.host,
           host.split(separator: ".").count == 1 {
            u = u.replacingOccurrences(of: "https://\(host)", with: "https://www.\(host)")
        }"""
assert old2 in c, 'open url not found'
c = c.replace(old2, new2)

with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('PATCHED BrowserManager')

# ============ 2. FloatingBrowser: 位置持久化 ============
path2 = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\FloatingBrowser.swift'
with io.open(path2, 'r', encoding='utf-8') as f:
    c2 = f.read()

old3 = """    private var dragStart: CGPoint = .zero
    private var lastExpandedCenter: CGPoint = .zero

    private init() {
        let s = UIScreen.main.bounds
        center = CGPoint(x: s.width * 0.55, y: s.height * 0.40)
    }"""
new3 = """    private var dragStart: CGPoint = .zero
    private var lastExpandedCenter: CGPoint = .zero
    // v2.9.98：悬浮窗位置记忆（重启后恢复到上次位置）
    private let posKey = "floating_browser_center"

    private init() {
        let s = UIScreen.main.bounds
        var x = s.width * 0.55
        var y = s.height * 0.40
        if let saved = UserDefaults.standard.string(forKey: posKey) {
            let parts = saved.split(separator: ",")
            if parts.count == 2, let px = Double(parts[0]), let py = Double(parts[1]) {
                x = CGFloat(px); y = CGFloat(py)
                x = min(max(x, s.width * 0.10), s.width * 0.90)
                y = min(max(y, s.height * 0.15), s.height * 0.85)
            }
        }
        center = CGPoint(x: x, y: y)
    }

    private func persistCenter() {
        UserDefaults.standard.set("\\(center.x),\\(center.y)", forKey: posKey)
    }"""
assert old3 in c2, 'fb init not found'
c2 = c2.replace(old3, new3)

# endDrag 里保存位置（两个分支尾部）
old4 = """        if isCollapsed {
            // 缩小态：贴右缘，y 夹在屏幕内
            center.x = capsuleX
            center.y = min(max(center.y, 60), screen.height - 60)
        } else {"""
new4 = """        if isCollapsed {
            // 缩小态：贴右缘，y 夹在屏幕内
            center.x = capsuleX
            center.y = min(max(center.y, 60), screen.height - 60)
            persistCenter()
        } else {"""
assert old4 in c2, 'fb endDrag collapsed not found'
c2 = c2.replace(old4, new4)

old5 = """                center.x = min(max(center.x, halfW), screen.width - halfW)
                center.y = min(max(center.y, halfH), screen.height - halfH)
            }"""
new5 = """                center.x = min(max(center.x, halfW), screen.width - halfW)
                center.y = min(max(center.y, halfH), screen.height - halfH)
                persistCenter()
            }"""
assert old5 in c2, 'fb endDrag expanded not found'
c2 = c2.replace(old5, new5)

with io.open(path2, 'w', encoding='utf-8') as f:
    f.write(c2)
print('PATCHED FloatingBrowser')
