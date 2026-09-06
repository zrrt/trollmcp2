import SwiftUI
import WebKit

// v2.9.39：内置浏览器悬浮窗（overlay 挂在 RootView 最上层）
// - 展开态：可拖动浏览器卡片（顶部渐变条拖动），可缩小/关闭
// - 缩小态：右侧边缘胶囊，点击展开，可上下拖动
// - AI 调用 browser.* 工具时自动浮现（FloatingBrowser.shared.show()）
struct FloatingBrowserOverlay: View {
    @ObservedObject private var fb = FloatingBrowser.shared
    @ObservedObject private var bm = BrowserManager.shared
    @State private var urlText = ""
    @State private var dragging = false
    @State private var isFullscreen = false   // v2.9.80：全屏模式

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if fb.isVisible {
                    if fb.isCollapsed {
                        capsuleView
                            .position(fb.center)
                            .gesture(dragGesture(minimumDistance: 12))
                    } else {
                        expandedView
                            .frame(width: isFullscreen ? geo.size.width * 0.98 : geo.size.width * 0.92,
                                   height: isFullscreen ? geo.size.height * 0.94 : geo.size.height * 0.60)
                            .position(fb.center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(fb.isVisible)
    }

    // MARK: - 缩小胶囊（v2.9.43：右缘半露悬浮球，中心 x=屏宽-22 → 左半圆露出、可点击展开）

    private var capsuleView: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.blue, Color.tmCyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
            Image(systemName: "safari.fill")
                .font(.system(size: 19))
                .foregroundColor(.white)
        }
        .frame(width: 46, height: 46)
        .contentShape(Circle())
        .onTapGesture { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { fb.expand() } }
    }

    // MARK: - 展开态浏览器

    private var expandedView: some View {
        VStack(spacing: 0) {
            // 顶部条：左半"抓手区"拖动移动窗口；右侧 −/× 按钮独立、即时响应（v2.9.43 修复按钮被拖动抢占）
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "safari.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                    Text(bm.pageTitle.isEmpty ? "内置浏览器" : bm.pageTitle)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(minimumDistance: 12))
                Spacer()
                Button(action: {
                    isFullscreen.toggle()
                    if isFullscreen {
                        let s = UIScreen.main.bounds.size
                        fb.setCenter(CGPoint(x: s.width / 2, y: s.height / 2))
                    }
                }) {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.22))
                        .clipShape(Circle())
                }
                Button(action: { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { fb.collapse() } }) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.22))
                        .clipShape(Circle())
                }
                Button(action: { fb.hide() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.22))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(LinearGradient(colors: [Color.blue, Color.tmCyan], startPoint: .leading, endPoint: .trailing))

            // URL 栏（v2.9.80：回车直接打开；v2.9.81：统一 submitURL，错误上屏）
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    TextField("输入网址，如 github.com", text: $urlText, onCommit: submitURL)
                        .font(.footnote)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .disableAutocorrection(true)
                        .padding(.leading, 10)
                    Button(action: { urlText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.trailing, 6)
                    }
                    .opacity(urlText.isEmpty ? 0 : 1)
                }
                .frame(height: 32)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                Button(action: submitURL) {
                    Text("打开")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.blue)
                        .cornerRadius(16)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // 控制条（后退/前进/刷新 + 外部打开 + 蓝框开关 + 元素数）
            HStack(spacing: 18) {
                controlButton("arrow.backward") { _ = bm.goBack() }
                controlButton("arrow.forward") { _ = bm.goForward() }
                controlButton("arrow.clockwise") { _ = bm.reload() }
                Spacer()
                // v2.9.80：外部打开（Safari）
                controlButton("arrow.up.right.square") {
                    if let u = URL(string: bm.currentURL), bm.currentURL != "about:blank" {
                        UIApplication.shared.open(u)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "highlighter")
                        .font(.caption2)
                        .foregroundColor(bm.highlighted ? .blue : .secondary)
                    Text("蓝框")
                        .font(.caption2)
                        .foregroundColor(bm.highlighted ? .blue : .secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(bm.highlighted ? Color.blue.opacity(0.14) : Color(.systemGray5))
                .cornerRadius(9)
                .onTapGesture {
                    bm.highlighted.toggle()
                    if bm.highlighted {
                        _ = bm.evalSync(BrowserManager.highlightScript)
                    } else {
                        _ = bm.evalSync("var o=document.querySelectorAll('[data-browser-idx]');for(var i=0;i<o.length;i++){o[i].style.outline='';o[i].removeAttribute('data-browser-idx');}")
                    }
                }
                if bm.elementCount > 0 {
                    Text("\(bm.elementCount) 元素")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)

            Divider()

            // 页面（复用 BrowserManager 单例 WKWebView）
            WebViewContainer(bm: bm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // v2.9.80：加载失败提示条
            if !bm.lastError.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text(bm.lastError)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                    Spacer()
                    Button("重试") { _ = bm.reload() }
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.08))
            }

            // 状态条（v2.9.80：AI 操作进度 / 加载指示）
            VStack(spacing: 3) {
                HStack {
                    if bm.isLoading {
                        ProgressView()
                            .scaleEffect(0.65)
                            .padding(.trailing, 2)
                    }
                    Text(bm.pageTitle.isEmpty ? bm.currentURL : bm.pageTitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("AI 用 browser.* 控制")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                if !bm.currentAction.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cursorarrow.click")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                        Text(bm.currentAction)
                            .font(.caption2)
                            .foregroundColor(.blue)
                            .lineLimit(1)
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground))
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
        .onAppear {
            bm.ensureWebView()
            // v2.9.81：只在从未加载过任何页面时自动开 Bing，
            // 避免自动加载覆盖用户/AI 刚发起的 URL（原 webView?.url == nil 判断有竞态）
            if !bm.hasLoadedAny {
                _ = bm.open("https://www.bing.com")
            }
        }
    }

    /// v2.9.81：统一 URL 提交（回车 / 打开按钮），失败信息显示到错误条
    private func submitURL() {
        let text = urlText
        urlText = ""
        guard !text.isEmpty else { return }
        let result = bm.open(text)
        if result.hasPrefix("ERR:") {
            bm.lastError = result.replacingOccurrences(of: "ERR: ", with: "")
        }
    }

    private func controlButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.blue)
                .frame(width: 34, height: 30)
        }
    }

    private func dragGesture(minimumDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance)
            .onChanged { v in
                if !dragging {
                    dragging = true
                    fb.beginDrag()
                }
                fb.drag(by: v.translation)
            }
            .onEnded { _ in
                dragging = false
                fb.endDrag()
            }
    }
}
