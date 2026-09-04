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

    private(set) var webView: WKWebView?
    private var loadedOnce = false

    private override init() {
        super.init()
    }

    // MARK: - WKWebView 创建

    func ensureWebView() {
        guard webView == nil else { return }
        if Thread.isMainThread {
            createWebView()
        } else {
            // WKWebView 必须在主线程创建；工具在后台线程调用，这里同步切主线程
            DispatchQueue.main.sync { createWebView() }
        }
    }

    private func createWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        webView = wv
    }

    // MARK: - 导航

    func open(_ urlString: String) -> String {
        ensureWebView()
        // v2.9.39：AI 打开网页时自动浮现悬浮窗，用户实时看到操作
        FloatingBrowser.shared.show()
        var u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return "ERR: 空 URL" }
        if !u.contains("://") { u = "https://" + u }
        guard let url = URL(string: u) else { return "ERR: 无效 URL" }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        DispatchQueue.main.async { self.webView?.load(req) }
        currentURL = url.absoluteString
        return "已开始加载 \(url.absoluteString)"
    }

    func goBack() -> String {
        ensureWebView()
        FloatingBrowser.shared.show()
        DispatchQueue.main.async {
            if self.webView?.canGoBack == true { self.webView?.goBack() }
        }
        return "后退"
    }

    func goForward() -> String {
        ensureWebView()
        FloatingBrowser.shared.show()
        DispatchQueue.main.async {
            if self.webView?.canGoForward == true { self.webView?.goForward() }
        }
        return "前进"
    }

    func reload() -> String {
        ensureWebView()
        FloatingBrowser.shared.show()
        DispatchQueue.main.async { self.webView?.reload() }
        return "刷新"
    }

    // MARK: - JS 同步执行（工具线程调用）

    /// 在后台线程同步等待 evaluateJavaScript 结果（主线程执行，避免死锁）
    func evalSync(_ js: String, timeout: TimeInterval = 15) -> String {
        ensureWebView()
        guard let wv = webView else { return "ERR: 浏览器未初始化" }
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
    static let highlightScript = """
    (function(){
      try{
        var old=document.querySelectorAll('[data-browser-idx]');
        for(var i=0;i<old.length;i++){ old[i].style.outline=''; old[i].removeAttribute('data-browser-idx'); }
        var els=document.querySelectorAll('a,button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"],summary,label,[onclick]');
        var idx=0, out=[];
        for(var i=0;i<els.length;i++){
          var e=els[i];
          var r=e.getBoundingClientRect();
          if(!r||r.width<5||r.height<5)continue;
          if(r.bottom<0||r.top>window.innerHeight||r.right<0||r.left>window.innerWidth)continue;
          var st=window.getComputedStyle(e);
          if(st.display==='none'||st.visibility==='hidden'||st.opacity==='0')continue;
          e.setAttribute('data-browser-idx',String(idx));
          e.style.outline='2px solid rgba(10,132,255,0.95)';
          e.style.outlineOffset='1px';
          var txt=(e.innerText||e.value||'').trim().replace(/\\s+/g,' ').slice(0,60);
          out.push({idx:idx,tag:e.tagName,text:txt,type:e.getAttribute('type')||'',name:e.getAttribute('name')||'',href:(e.getAttribute('href')||'').slice(0,90),placeholder:e.getAttribute('placeholder')||'',value:(e.value||'').slice(0,40)});
          idx++;
        }
        return JSON.stringify(out);
      }catch(err){ return 'ERR: '+err.message; }
    })();
    """

    /// 注入高亮并返回元素快照 JSON（AI 调用时自动浮现悬浮窗）
    func snapshot() -> [String: Any] {
        ensureWebView()
        FloatingBrowser.shared.show()
        let json = evalSync(Self.highlightScript)
        lastSnapshot = json
        var result: [String: Any] = ["url": currentURL, "title": pageTitle]
        if json.hasPrefix("ERR:") {
            result["error"] = json
            result["elements"] = []
            elementCount = 0
            return result
        }
        if let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            result["elements"] = arr
            result["count"] = arr.count
            elementCount = arr.count
        } else {
            result["elements"] = []
            result["count"] = 0
            elementCount = 0
        }
        return result
    }

    /// 点击元素（按快照 idx）
    func clickElement(_ idx: Int) -> String {
        FloatingBrowser.shared.show()
        let js = "(function(){var e=document.querySelector('[data-browser-idx=\\\"\(idx)\\\"]');if(!e)return 'ERR: 元素 '+\(idx)+' 不存在（页面可能已变化，请重新 snapshot）';var t=(e.innerText||e.value||'').trim().slice(0,40);e.click();return '已点击 '+e.tagName+' '+JSON.stringify(t);})();"
        return evalSync(js)
    }

    /// 填表（按快照 idx + 文本）
    func typeText(_ idx: Int, _ text: String) -> String {
        FloatingBrowser.shared.show()
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
        return evalSync(js)
    }

    /// 执行任意 JS（AI 调用时自动浮现悬浮窗）
    func evaluate(_ js: String) -> String {
        FloatingBrowser.shared.show()
        return evalSync(js)
    }

    /// 当前状态
    func status() -> [String: Any] {
        ensureWebView()
        var r: [String: Any] = [
            "url": currentURL,
            "title": pageTitle,
            "highlighted": highlighted,
            "elementCount": elementCount,
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
        // 页面加载完成自动高亮（用户打开浏览器即可看到蓝框交互元素）
        if highlighted {
            _ = evalSync(Self.highlightScript)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageTitle = "加载失败"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageTitle = "无法访问"
        currentURL = webView.url?.absoluteString ?? currentURL
    }
}
