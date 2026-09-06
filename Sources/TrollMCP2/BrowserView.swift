import SwiftUI
import WebKit

// v2.9.37：内置浏览器界面（AI 可控，元素蓝框高亮）
struct BrowserView: View {
    @ObservedObject private var bm = BrowserManager.shared
    @State private var urlText = ""
    @State private var isFullscreen = false
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !isFullscreen {
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
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .padding(.trailing, 6)
                        }
                        .opacity(urlText.isEmpty ? 0 : 1)
                    }
                    .frame(height: 34)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(17)
                    Button(action: { bm.open(urlText); urlText = "" }) {
                        Text("打开")
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Color.blue)
                            .cornerRadius(17)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // 控制条
                HStack(spacing: 20) {
                    controlButton("arrow.backward", "后退") { bm.goBack() }
                    controlButton("arrow.forward", "前进") { bm.goForward() }
                    controlButton("arrow.clockwise", "刷新") { bm.reload() }
                    Spacer()
                    // 高亮开关（蓝框）
                    HStack(spacing: 6) {
                        Image(systemName: "highlighter")
                            .font(.caption)
                            .foregroundColor(bm.highlighted ? .blue : .secondary)
                        Text("蓝框")
                            .font(.caption)
                            .foregroundColor(bm.highlighted ? .blue : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(bm.highlighted ? Color.blue.opacity(0.14) : Color(.systemGray5))
                    .cornerRadius(10)
                    .onTapGesture {
                        bm.highlighted.toggle()
                        toggleHighlight()
                    }
                    if bm.elementCount > 0 {
                        Text("\(bm.elementCount) 元素")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                Divider()
                }

                // 页面
                WebViewContainer(bm: bm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // v2.9.80：加载失败提示（与悬浮窗保持一致）
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.08))
                }

                // 底部状态条（全屏时也保留，显示 AI 操作进度）
                VStack(spacing: 4) {
                    HStack {
                        if isFullscreen {
                            Button(action: { isFullscreen = false }) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                        Text(bm.pageTitle.isEmpty ? bm.currentURL : "\(bm.pageTitle)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("AI 可用 browser.snapshot")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    if !bm.currentAction.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(bm.currentAction)
                                .font(.caption2)
                                .foregroundColor(.blue)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("内置浏览器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { bm.open("https://www.bing.com") }) {
                        Text("主页")
                            .font(.footnote)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: { isFullscreen.toggle() }) {
                            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.footnote)
                        }
                        Button("完成") { presentationMode.wrappedValue.dismiss() }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            bm.ensureWebView()
            if bm.webView?.url == nil || bm.currentURL == "about:blank" {
                bm.open("https://www.bing.com")
            }
            urlText = ""
        }
    }

    private func controlButton(_ icon: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.blue)
                .frame(width: 36, height: 32)
        }
    }

    private func toggleHighlight() {
        if bm.highlighted {
            _ = bm.evalSync(BrowserManager.highlightScript)
        } else {
            _ = bm.evalSync("var o=document.querySelectorAll('[data-browser-idx]');for(var i=0;i<o.length;i++){o[i].style.outline='';o[i].removeAttribute('data-browser-idx');}")
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    let bm: BrowserManager

    func makeUIView(context: Context) -> WKWebView {
        bm.ensureWebView()
        return bm.webView!
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
