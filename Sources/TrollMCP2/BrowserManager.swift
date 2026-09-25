import Foundation
import WebKit
import Combine

// v2.9.37：内置浏览器管理器（AI 可控）
// - 单例持有 WKWebView，供 MCP 工具与 BrowserView 共用
// - 蓝框高亮：注入 JS 给可交互元素加 data-browser-idx + 蓝色 outline，AI 按 idx 点击/填表
// - evalSync：工具在后台线程调用，主线程执行 evaluateJavaScript，信号量同步等待
final class BrowserManager: NSObject, ObservableObject, WKNavigationDelegate {

    static let shared = BrowserManager()

    @Published var currentURL: String = "about:blank"
    @Published var pageTitle: String = ""
    @Published var highlighted = true          // 蓝框高亮开关
    @Published var elementCount = 0
    @Published var lastSnapshot = ""           // 最近一次元素快照 JSON 字符串
    @Published var currentAction = ""          // v2.9.67：AI 当前正在执行的浏览器操作描述
    // v2.9.80：加载状态与错误（overlay 显示加载进度 / 失败提示）
    @Published var isLoading = false
    @Published var lastError = ""

    private(set) var webView: WKWebView?
    // v2.9.81：是否已加载过任意页面（替代从未赋值的 loadedOnce）
    // 悬浮窗 onAppear 只在从未加载过时自动开 Bing，避免自动加载覆盖用户/AI 刚发起的 URL
    private(set) var hasLoadedAny = false

    private override init() {
        super.init()
    }

    // MARK: - WKWebView 创建

    /// v2.9.251: 返回 Bool——主线程 busy 时 main.sync 死锁(远程终端后台线程调用浏览器工具挂起),
    /// 改 main.async + 5s 超时信号量,超时返回 false 由调用方报错而非死锁
    @discardableResult
    func ensureWebView() -> Bool {
        guard webView == nil else { return true }
        // v3.5.16j：首次调用主动初始化并重试——此前 5s 单次超时，主线程忙/WebView 建得慢时
        // 直接返回 ERR("浏览器 WebView 初始化超时")，导致 browser.navigate 前几次报 ok=false/UNKNOWN。
        // 现在最多重试 4 次、每次 2s（共约 8s），期间主线程空闲后 WebView 建成就成功。
        for _ in 0..<4 {
            if Thread.isMainThread {
                createWebView()
                if webView != nil { return true }
            } else {
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    if self.webView == nil { self.createWebView() }
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 2)
                if webView != nil { return true }
            }
            // 未成功则稍等再试，给主线程腾空
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func createWebView() {
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
    }

    // v2.9.251: ensureWebView 超时/失败的统一错误返回（String 返回型工具）
    private func errInit() -> String {
        return "ERR: 浏览器 WebView 初始化超时（主线程忙或系统限制），请重试"
    }

    // MARK: - 操作进度（AI 工具调用时设置，悬浮窗底部显示）

    private func beginAction(_ desc: String) {
        DispatchQueue.main.async {
            self.currentAction = desc
            self.isLoading = false
        }
    }

    private func endAction() {
        DispatchQueue.main.async {
            self.currentAction = ""
            self.isLoading = false
        }
    }

    // MARK: - 导航

    /// 打开网页（v2.9.81：URL 规范化 + 明确报错 + hasLoadedAny 标记，修自动 Bing 覆盖用户输入的竞态）
    func open(_ urlString: String) -> String {
        guard ensureWebView() else { return errInit() }
        // v2.9.39：AI 打开网页时自动浮现悬浮窗，用户实时看到操作
        FloatingBrowser.shared.show()
        var u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let hasSpaceOrCN = u.contains(" ") || u.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil
            let hasDot = u.contains(".")
            if isIP || isLocal {
                u = "http://" + u
            } else if hasSpaceOrCN || !hasDot {
                let q = u.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? u
                u = "https://www.bing.com/search?q=\(q)"
            } else {
                u = "https://" + u
            }
        }
        // 裸域名补 www（部分站点裸域 https 不响应，如 example.com → www.example.com）
        if let host = URL(string: u)?.host,
           host.split(separator: ".").count == 1 {
            u = u.replacingOccurrences(of: "https://\(host)", with: "https://www.\(host)")
        }
        guard let url = URL(string: u) else { return "ERR: 无效 URL" }
        guard let wv = webView else { return "ERR: 浏览器未初始化" }
        hasLoadedAny = true
        beginAction("正在打开 \(url.host ?? urlString)")
        DispatchQueue.main.async {
            self.isLoading = true
            self.lastError = ""
            let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            wv.load(req)
        }
        currentURL = url.absoluteString
        AuditLog.shared.log("browser.open", detail: "\(urlString) → \(url.absoluteString)")
        return "已开始加载 \(url.absoluteString)"
    }

    func goBack() -> String {
        guard ensureWebView() else { return errInit() }
        FloatingBrowser.shared.show()
        hasLoadedAny = true
        beginAction("后退")
        DispatchQueue.main.async {
            if self.webView?.canGoBack == true { self.webView?.goBack() }
        }
        return "后退"
    }

    func goForward() -> String {
        guard ensureWebView() else { return errInit() }
        FloatingBrowser.shared.show()
        hasLoadedAny = true
        beginAction("前进")
        DispatchQueue.main.async {
            if self.webView?.canGoForward == true { self.webView?.goForward() }
        }
        return "前进"
    }

    func reload() -> String {
        guard ensureWebView() else { return errInit() }
        FloatingBrowser.shared.show()
        hasLoadedAny = true
        beginAction("刷新页面")
        DispatchQueue.main.async {
            self.isLoading = true
            self.lastError = ""
            self.webView?.reload()
        }
        return "刷新"
    }

    // MARK: - v2.9.88 AI 可控浏览器补强：等待 / 正文提取 / 滚动 / 表单提交

    /// 等待页面加载完成（最多 timeout 秒）。open 后必须 wait，否则 snapshot 拿不到元素。
    func wait(timeout: Int = 15) -> [String: Any] {
        guard ensureWebView() else { return ["ok": false, "error": "浏览器初始化超时"] }
        FloatingBrowser.shared.show()
        beginAction("等待页面加载…")
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var ready = false
        while Date() < deadline {
            let state = evalSync("document.readyState", timeout: 5)
            if state == "complete" || state == "interactive" {
                ready = true
                break
            }
            if isLoading == false && !lastError.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // 加载完成后重新高亮
        if ready || highlighted {
            _ = evalSync(Self.highlightScript)
        }
        endAction()
        var r: [String: Any] = [
            "url": currentURL,
            "title": pageTitle,
            "loaded": ready
        ]
        // v3.1.8：只有真的有错误时才放 error 键，避免框架把 nil error 当成错误
        if !lastError.isEmpty {
            r["error"] = lastError
        }
        // 顺带返回页面正文长度，方便 AI 判断内容是否就位
        let textLen = evalSync("(document.body && document.body.innerText || '').length")
        r["body_text_length"] = Int(textLen) ?? 0
        return r
    }

    /// 提取页面可见正文（供 AI 阅读/总结页面内容）。可选 query 做关键词上下文截取。
    func getText(maxChars: Int = 3000, query: String? = nil) -> String {
        guard ensureWebView() else { return errInit() }
        FloatingBrowser.shared.show()
        beginAction("提取页面正文…")
        let js = """
        (function(){
          var t=(document.body&&document.body.innerText||'').replace(/\\s+\\n/g,'\\n').replace(/\\n{3,}/g,'\\n\\n').trim();
          return t;
        })();
        """
        var text = evalSync(js, timeout: 10)
        if text.hasPrefix("ERR:") { endAction(); return text }
        if let q = query, !q.isEmpty {
            // 找关键词附近上下文：前后各 400 字符
            if let range = text.range(of: q, options: .caseInsensitive) {
                let lo = text.index(range.lowerBound, offsetBy: -min(400, text.distance(from: text.startIndex, to: range.lowerBound)), limitedBy: text.startIndex) ?? text.startIndex
                let hi = text.index(range.upperBound, offsetBy: min(400, text.distance(from: range.upperBound, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex
                text = "…\(text[lo..<hi])…"
            } else {
                text = "未找到关键词「\(q)」上下文，返回开头：\n" + String(text.prefix(800))
            }
        } else {
            text = String(text.prefix(maxChars))
        }
        endAction()
        return text
    }

    /// 页面滚动：down / up / top / bottom
    func scroll(_ direction: String) -> String {
        guard ensureWebView() else { return errInit() }
        FloatingBrowser.shared.show()
        beginAction("滚动页面（\(direction)）")
        let js: String
        switch direction {
        case "down": js = "window.scrollBy(0, window.innerHeight*0.8); 'scrolled down'"
        case "up": js = "window.scrollBy(0, -window.innerHeight*0.8); 'scrolled up'"
        case "top": js = "window.scrollTo(0,0); 'scrolled to top'"
        case "bottom": js = "window.scrollTo(0, document.body.scrollHeight); 'scrolled to bottom'"
        default: endAction(); return "ERR: direction 只支持 down/up/top/bottom"
        }
        let r = evalSync(js)
        _ = evalSync(Self.highlightScript)   // 滚动后元素位置变化，刷新蓝框编号
        endAction()
        return r
    }

    /// 表单提交：在指定输入框按回车（触发 submit），或直接提交整个 form
    func submit(_ idx: Int) -> String {
        FloatingBrowser.shared.show()
        beginAction("提交表单（元素 #\(idx)）…")
        ensureMarked()
        let js = """
        (function(){
          var e=document.querySelector('[data-browser-idx="\(idx)"]');
          if(!e)return 'ERR: 元素 '+\(idx)+' 不存在（页面可能已变化，请重新 snapshot）';
          var form=e.closest('form');
          if(form){form.requestSubmit();return '已提交表单 (form submit)';}
          var ev=new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true});
          e.dispatchEvent(ev);
          return '已发送回车键 (Enter)';
        })();
        """
        let r = evalSync(js)
        if !r.hasPrefix("ERR") {
            _ = evalSync(Self.highlightScript)
        }
        endAction()
        return r
    }

    // MARK: - v2.9.130 表单整表填充 / 字段扫描 / 元素等待（对齐 Playwright fill + waitFor 设计）

    /// 扫描页面全部表单字段（不限 snapshot 30 条），返回 name/placeholder/label/type/xpath
    func formFields() -> [String: Any] {
        guard ensureWebView() else { return ["ok": false, "error": "浏览器初始化超时"] }
        FloatingBrowser.shared.show()
        beginAction("扫描表单字段…")
        let js = """
        (function(){
          function xpath(e){
            if(e&&e.nodeType===1&&e.id){ return '//*[@id="'+e.id.replace(/"/g,'\\\\"')+'"]'; }
            var parts=[];
            while(e&&e.nodeType===1){
              var sib=e.parentNode?Array.prototype.filter.call(e.parentNode.children,function(c){return c.tagName===e.tagName;}):[];
              var nth=sib.length>1?'['+(sib.indexOf(e)+1)+']':'';
              parts.unshift(e.tagName.toLowerCase()+nth);
              if(e.id){parts.unshift('//*[@id="'+e.id.replace(/"/g,'\\\\"')+'"]');break;}
              e=e.parentNode;
            }
            return parts.length?'//'+parts.join('/'):'';
          }
          var out=[];
          document.querySelectorAll('input,textarea,select').forEach(function(e){
            var r=e.getBoundingClientRect();
            var st=window.getComputedStyle(e);
            if(!r||r.width<3||r.height<3)return;
            if(st.display==='none'||st.visibility==='hidden'||st.opacity==='0')return;
            var lab='';
            if(e.labels&&e.labels[0])lab=(e.labels[0].innerText||'').trim().replace(/\\s+/g,' ').slice(0,40);
            var opts=[];
            if(e.tagName==='SELECT'){ Array.prototype.forEach.call(e.options,function(o){opts.push((o.text||'').trim().slice(0,30));}); }
            out.push({name:e.getAttribute('name')||'',placeholder:e.getAttribute('placeholder')||'',type:e.getAttribute('type')||(e.tagName==='TEXTAREA'?'textarea':(e.tagName==='SELECT'?'select':'text')),label:lab,value:(e.value||'').slice(0,40),checked:!!e.checked,options:opts,xpath:xpath(e),tag:e.tagName});
          });
          return JSON.stringify(out);
        })();
        """
        let json = evalSync(js, timeout: 10)
        endAction()
        if json.hasPrefix("ERR:") { return ["ok": false, "error": json] }
        var fields: [[String: Any]] = []
        if let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            fields = arr
        }
        return ["ok": true, "count": fields.count, "fields": fields,
                "hint": "用 browser.fill_form 传 {\"字段名或占位符或标签\":\"值\"}，如 {\"用户名\":\"me\",\"密码\":\"xx\"}；下拉框传选项文字；勾选框传 true/false；需要精确时传 {\"__xpath\":\"//*[@id='x'\",\"__value\":\"v\"}"]
    }

    /// 整表自动填充：values 键匹配 name/placeholder/label，填完可选提交表单
    /// v2.9.130：React/Vue 受控组件用 native value setter + input/change 事件（同 Playwright fill）；
    /// select 按选项文字/值匹配；checkbox/radio 按 true/false 点击；支持 __xpath 精确指定
    func fillForm(values: [String: String], submit: Bool) -> [String: Any] {
        guard ensureWebView() else { return ["ok": false, "error": "浏览器初始化超时"] }
        FloatingBrowser.shared.show()
        beginAction("自动填充表单…")
        var js = """
        (function(){
          function xpath(e){
            if(e&&e.nodeType===1&&e.id){ return '//*[@id="'+e.id.replace(/"/g,'\\\\"')+'"]'; }
            var parts=[];
            while(e&&e.nodeType===1){
              var sib=e.parentNode?Array.prototype.filter.call(e.parentNode.children,function(c){return c.tagName===e.tagName;}):[];
              var nth=sib.length>1?'['+(sib.indexOf(e)+1)+']':'';
              parts.unshift(e.tagName.toLowerCase()+nth);
              if(e.id){parts.unshift('//*[@id="'+e.id.replace(/"/g,'\\\\"')+'"]');break;}
              e=e.parentNode;
            }
            return parts.length?'//'+parts.join('/'):'';
          }
          function setVal(e,val){
            if(!e)return false;
            if(e.tagName==='SELECT'){
              var found=false;
              Array.prototype.forEach.call(e.options,function(o){ if(o.value===val||(o.text||'').indexOf(val)>=0){e.value=o.value;found=true;} });
              e.dispatchEvent(new Event('change',{bubbles:true}));
              return found||val==='';
            }
            if(e.type==='checkbox'||e.type==='radio'){
              var want=(val==='true'||val==='1'||val==='yes'||val==='on'||val==='勾选'||val==='选中'||val==='true');
              if(e.checked!==want){e.click();}
              e.dispatchEvent(new Event('change',{bubbles:true}));
              return true;
            }
            e.focus();
            var proto=e instanceof HTMLTextAreaElement?window.HTMLTextAreaElement.prototype:(e instanceof HTMLInputElement?window.HTMLInputElement.prototype:null);
            if(proto){var setter=Object.getOwnPropertyDescriptor(proto,'value').set;setter.call(e,val);}else{e.value=val;}
            e.dispatchEvent(new Event('input',{bubbles:true}));
            e.dispatchEvent(new Event('change',{bubbles:true}));
            return true;
          }
          var fields=[];
          document.querySelectorAll('input,textarea,select').forEach(function(e){
            var r=e.getBoundingClientRect();
            var st=window.getComputedStyle(e);
            if(!r||r.width<3||r.height<3)return;
            if(st.display==='none'||st.visibility==='hidden'||st.opacity==='0')return;
            var lab='';
            if(e.labels&&e.labels[0])lab=(e.labels[0].innerText||'').trim();
            fields.push({name:e.getAttribute('name')||'',placeholder:e.getAttribute('placeholder')||'',label:lab,xpath:xpath(e)});
          });
          var map=MAP;
          var filled=0, missed=[];
          if(map.__xpath&&('__value' in map)){
            if(setVal(document.querySelector(map.__xpath),map.__value)){filled++;}
            else{missed.push('__xpath');}
          }
          Object.keys(map).forEach(function(key){
            if(key==='__xpath'||key==='__value')return;
            var target=null;
            for(var i=0;i<fields.length;i++){
              var f=fields[i];
              if(f.name===key||f.placeholder===key||f.label===key){target=f;break;}
            }
            if(!target){
              for(var j=0;j<fields.length;j++){
                var ff=fields[j];
                if((ff.name+' '+ff.placeholder+' '+ff.label).indexOf(key)>=0){target=ff;break;}
              }
            }
            if(target&&setVal(document.querySelector(target.xpath),map[key])){filled++;}
            else{missed.push(key);}
          });
          var submitted=false;
          if(SUBMIT){
            var first=document.querySelector('input[type="submit"],button[type="submit"],form');
            if(first){if(first.tagName==='FORM'){first.requestSubmit();}else{var fm=first.closest('form');if(fm){fm.requestSubmit();}else{first.click();}}submitted=true;}
          }
          return JSON.stringify({filled:filled,missed:missed,submitted:submitted});
        })();
        """
        js = js.replacingOccurrences(of: "MAP", with: JSONString(mapString(values)))
        js = js.replacingOccurrences(of: "SUBMIT", with: submit ? "true" : "false")
        let r = evalSync(js, timeout: 15)
        endAction()
        if r.hasPrefix("ERR:") { return ["ok": false, "error": r] }
        if let data = r.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var result: [String: Any] = ["ok": true]
            result["filled"] = o["filled"]
            result["missed"] = o["missed"]
            result["submitted"] = o["submitted"]
            return result
        }
        return ["ok": true, "raw": r]
    }

    /// 等待元素出现（selector 或正文文本），用于 open 后等搜索结果/登录态
    func waitFor(text: String? = nil, selector: String? = nil, timeout: Int = 15) -> [String: Any] {
        guard ensureWebView() else { return ["ok": false, "error": "浏览器初始化超时"] }
        FloatingBrowser.shared.show()
        beginAction("等待目标出现…")
        if let s = selector, !s.isEmpty {
            let sj = JSONString(s)
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            var found = false
            while Date() < deadline {
                if evalSync("!!document.querySelector(\(sj))", timeout: 5) == "true" { found = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            endAction()
            return ["ok": true, "found": found, "selector": s, "waited_seconds": timeout]
        }
        if let t = text, !t.isEmpty {
            let tj = JSONString(t)
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            var found = false
            while Date() < deadline {
                let hit = evalSync("(document.body.innerText||'').indexOf(\(tj))>=0", timeout: 5)
                if hit == "true" { found = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            endAction()
            return ["ok": true, "found": found, "text": t, "waited_seconds": timeout]
        }
        endAction()
        return ["ok": false, "error": "需要 selector 或 text 参数"]
    }

    private func mapString(_ d: [String: String]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    // MARK: - JS 同步执行（工具线程调用）

    /// 在后台线程同步等待 evaluateJavaScript 结果（主线程执行，避免死锁）
    func evalSync(_ js: String, timeout: TimeInterval = 15) -> String {
        guard ensureWebView() else { return errInit() }
        guard let wv = webView else { return "ERR: 浏览器未初始化" }
        // v2.9.44：主线程调用会死锁（main.async 排队 + semaphore.wait 阻塞主线程），安全返回
        if Thread.isMainThread {
            return "ERR: evalSync 不能在主线程调用（会阻塞 UI），请用异步 evaluateJavaScript"
        }
        var result = "ERR: 执行超时"
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            wv.evaluateJavaScript(js) { obj, err in
                if let obj = obj {
                    result = "\(obj)"
                } else if let err = err {
                    result = "ERR: \(err.localizedDescription)"
                } else {
                    result = ""
                }
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return result
    }

    // MARK: - 高亮与快照

    /// 高亮脚本：清除旧标记 → 给可见可交互元素加 data-browser-idx + 蓝框 → 返回元素 JSON 数组
    /// 注入高亮并返回元素快照 JSON（AI 调用时自动浮现悬浮窗）
    /// v2.9.44：支持 query 关键字过滤（按文本/标签/占位符/name/href 模糊匹配），长页面不爆 token
    /// v2.9.80：元素带 x/y/w/h 坐标
    /// v2.9.129：去掉"只抓视口内元素"的过滤——小悬浮窗里 Bing 搜索结果第一屏只有 1 条链接，
    /// 其余结果在视口外被裁剪导致 snapshot 只返回 1 条。改为只过滤尺寸/显示，全页可点元素入列，
    /// 靠 prefix(30) 截断；JS click 对不可见元素同样有效，AI 拿到 idx 即可操作
    /// v2.9.130：每个元素带绝对 xpath——idx 因页面变化失效时可用 xpath 兜底定位
    static let highlightScript = """
    (function(){
      try{
        function xpath(e){
          if(e&&e.nodeType===1&&e.id){ return '//*[@id="'+e.id.replace(/"/g,'\\\\"')+'"]'; }
          var parts=[];
          while(e&&e.nodeType===1){
            var sib=e.parentNode?Array.prototype.filter.call(e.parentNode.children,function(c){return c.tagName===e.tagName;}):[];
            var nth=sib.length>1?'['+(sib.indexOf(e)+1)+']':'';
            parts.unshift(e.tagName.toLowerCase()+nth);
            if(e.id){parts.unshift('//*[@id="'+e.id.replace(/"/g,'\\\\"')+'"]');break;}
            e=e.parentNode;
          }
          return parts.length?'//'+parts.join('/'):'';
        }
        var old=document.querySelectorAll('[data-browser-idx]');
        for(var i=0;i<old.length;i++){ old[i].style.outline=''; old[i].removeAttribute('data-browser-idx'); }
        var els=document.querySelectorAll('a,button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"],summary,label,[onclick]');
        var idx=0, out=[];
        for(var i=0;i<els.length;i++){
          var e=els[i];
          var r=e.getBoundingClientRect();
          if(!r||r.width<5||r.height<5)continue;
          var st=window.getComputedStyle(e);
          if(st.display==='none'||st.visibility==='hidden'||st.opacity==='0')continue;
          e.setAttribute('data-browser-idx',String(idx));
          e.style.outline='2px solid rgba(10,132,255,0.95)';
          e.style.outlineOffset='1px';
          var txt=(e.innerText||e.value||'').trim().replace(/\\s+/g,' ').slice(0,60);
          out.push({idx:idx,tag:e.tagName,text:txt,type:e.getAttribute('type')||'',name:e.getAttribute('name')||'',href:(e.getAttribute('href')||'').slice(0,90),placeholder:e.getAttribute('placeholder')||'',value:(e.value||'').slice(0,40),x:Math.round(r.left),y:Math.round(r.top),w:Math.round(r.width),h:Math.round(r.height),xpath:xpath(e)});
          idx++;
        }
        return JSON.stringify(out);
      }catch(err){ return 'ERR: '+err.message; }
    })();
    """

    /// 注入高亮并返回元素快照 JSON（AI 调用时自动浮现悬浮窗）
    /// v2.9.44：支持 query 关键字过滤（按文本/标签/占位符/name/href 模糊匹配），长页面不爆 token
    /// v2.9.80：元素带 x/y/w/h 坐标
    func snapshot(query: String? = nil) -> [String: Any] {
        guard ensureWebView() else { return ["ok": false, "error": "浏览器初始化超时"] }
        FloatingBrowser.shared.show()
        beginAction("扫描页面可交互元素…")
        let json = evalSync(Self.highlightScript)
        endAction()
        lastSnapshot = json
        var result: [String: Any] = ["url": currentURL, "title": pageTitle]
        if json.hasPrefix("ERR:") {
            result["error"] = json
            result["elements"] = []
            elementCount = 0
            return result
        }
        if let data = json.data(using: .utf8),
           let arr0 = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var arr = arr0
            if let q = query, !q.isEmpty {
                let lq = q.lowercased()
                arr = arr.filter { el in
                    let hay = "\(el["text"] ?? "") \(el["tag"] ?? "") \(el["placeholder"] ?? "") \(el["name"] ?? "") \(el["href"] ?? "")".lowercased()
                    return hay.contains(lq)
                }
                result["query"] = q
                result["matched"] = arr.count
            }
            result["elements"] = Array(arr.prefix(30))
            result["count"] = arr.count
            result["truncated"] = arr.count > 30
            elementCount = arr.count
        } else {
            result["elements"] = []
            result["count"] = 0
            elementCount = 0
        }
        return result
    }

    /// 确保页面已有 data-browser-idx 标记（蓝框关闭 / 页面跳转后重打标，否则 AI click/type 会失败）
    private func ensureMarked() {
        let check = evalSync("document.querySelectorAll('[data-browser-idx]').length")
        if check == "0" || check.hasPrefix("ERR") {
            _ = evalSync(Self.highlightScript)
        }
    }

    /// 点击元素（按快照 idx）；点击后自动重新高亮，刷新蓝框编号避免旧 idx
    /// v2.9.80：点击前先确保标记存在（修蓝框关闭后必失败 bug）；点击时目标蓝色闪烁，用户能看到 AI 点了哪里
    func clickElement(_ idx: Int) -> String {
        FloatingBrowser.shared.show()
        beginAction("点击元素 #\(idx)…")
        ensureMarked()
        let js = "(function(){var e=document.querySelector('[data-browser-idx=\\\"\(idx)\\\"]');if(!e)return 'ERR: 元素 '+\(idx)+' 不存在（页面可能已变化，请重新 snapshot）';var t=(e.innerText||e.value||'').trim().slice(0,40);var orig=e.style.outline;e.style.outline='3px solid rgba(0,200,255,1)';e.style.outlineOffset='2px';setTimeout(function(){e.style.outline=orig;},900);e.click();return '已点击 '+e.tagName+' '+JSON.stringify(t);})();"
        let r = evalSync(js)
        if !r.hasPrefix("ERR") {
            _ = evalSync(Self.highlightScript)   // 点击后页面可能变化，刷新编号
        }
        endAction()
        return r
    }

    /// 填表（按快照 idx + 文本）
    func typeText(_ idx: Int, _ text: String) -> String {
        FloatingBrowser.shared.show()
        beginAction("向元素 #\(idx) 输入文本…")
        ensureMarked()
        let t = JSONString(text)
        let js = """
        (function(){
          var e=document.querySelector('[data-browser-idx="\(idx)"]');
          if(!e)return 'ERR: 元素 '+\(idx)+' 不存在（页面可能已变化，请重新 snapshot）';
          e.focus();
          var proto=e instanceof HTMLTextAreaElement?window.HTMLTextAreaElement.prototype:(e instanceof HTMLInputElement?window.HTMLInputElement.prototype:null);
          if(proto){var setter=Object.getOwnPropertyDescriptor(proto,'value').set;setter.call(e,\(t));}
          else{e.value=\(t);}
          e.dispatchEvent(new Event('input',{bubbles:true}));
          e.dispatchEvent(new Event('change',{bubbles:true}));
          return '已输入: '+\(t);
        })();
        """
        let r = evalSync(js)
        endAction()
        return r
    }

    /// 执行任意 JS（AI 调用时自动浮现悬浮窗）
    func evaluate(_ js: String) -> String {
        FloatingBrowser.shared.show()
        beginAction("执行 JavaScript…")
        let r = evalSync(js)
        endAction()
        return r
    }

    /// 当前状态
    func status() -> [String: Any] {
        guard ensureWebView() else { return ["ok": false, "error": "浏览器初始化超时"] }
        var r: [String: Any] = [
            "url": currentURL,
            "title": pageTitle,
            "highlighted": highlighted,
            "elementCount": elementCount,
            "loading": isLoading,
            "hint": "先用 browser.snapshot 获取可交互元素（蓝框编号），再按 idx 用 browser.click / browser.type 操作"
        ]
        if let wv = webView {
            r["canGoBack"] = wv.canGoBack
            r["canGoForward"] = wv.canGoForward
        }
        return r
    }

    private func JSONString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\""
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url?.absoluteString ?? currentURL
        pageTitle = webView.title ?? ""
        // v2.9.80：加载完成清理状态
        DispatchQueue.main.async {
            self.isLoading = false
            self.currentAction = ""
            self.lastError = ""
        }
        // v2.9.44：修复主线程死锁——didFinish 在主线程回调，不能用 evalSync
        // （其内部 main.async + semaphore.wait 会阻塞主线程 15s → 浏览器卡死/页面空白）
        if highlighted {
            webView.evaluateJavaScript(Self.highlightScript) { [weak self] obj, _ in
                guard let self = self else { return }
                if let s = obj as? String, let d = s.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                    DispatchQueue.main.async { self.elementCount = arr.count }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageTitle = "加载失败"
        DispatchQueue.main.async {
            self.isLoading = false
            self.currentAction = ""
            self.lastError = "加载失败：\((error as NSError).localizedDescription.prefix(60))"
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageTitle = "无法访问"
        currentURL = webView.url?.absoluteString ?? currentURL
        DispatchQueue.main.async {
            self.isLoading = false
            self.currentAction = ""
            self.lastError = "无法访问：\((error as NSError).localizedDescription.prefix(60))"
        }
    }
}
