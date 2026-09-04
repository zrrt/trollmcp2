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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if fb.isVisible {
                    if fb.isCollapsed {
                        capsuleView
                            .position(x: geo.size.width - 28, y: fb.center.y)
                            .gesture(dragGesture(minimumDistance: 12))
                    } else {
                        expandedView
                            .frame(width: geo.size.width * 0.92, height: geo.size.height * 0.60)
                            .position(fb.center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(fb.isVisible)
    }

    // MARK: - 缩小胶囊（贴右侧边缘，可上下拖动，点击展开）

    private var capsuleView: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.blue, Color.tmCyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
            Image(systemName: "safari.fill")
                .font(.system(size: 18))
                .foregroundColor(.white)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .onTapGesture { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { fb.expand() } }
    }

    // MARK: - 展开态浏览器

    private var expandedView: some View {
        VStack(spacing: 0) {
            // 顶部拖动条（可拖动移动窗口 + 缩小 + 关闭）
            HStack(spacing: 10) {
                Image(systemName: "safari.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                Text(bm.pageTitle.isEmpty ? "内置浏览器" : bm.pageTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Button(action: { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { fb.collapse() } }) {
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
            .contentShape(Rectangle())
            .gesture(dragGesture)

            // URL 栏
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    TextField("输入网址，如 github.com", text: $urlText)
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
                Button(action: { bm.open(urlText); urlText = "" }) {
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

            // 控制条（后退/前进/刷新 + 蓝框开关 + 元素数）
            HStack(spacing: 18) {
                controlButton("arrow.backward") { _ = bm.goBack() }
                controlButton("arrow.forward") { _ = bm.goForward() }
                controlButton("arrow.clockwise") { _ = bm.reload() }
                Spacer()
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

            // 状态条
            HStack {
                Text(bm.pageTitle.isEmpty ? bm.currentURL : bm.pageTitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("AI 用 browser.* 控制")
                    .font(.caption2)
                    .foregroundColor(.blue)
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
            if bm.webView?.url == nil || bm.currentURL == "about:blank" {
                bm.open("https://www.baidu.com")
            }
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

    private var dragGesture: some Gesture {
        dragGesture(minimumDistance: 2)
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
