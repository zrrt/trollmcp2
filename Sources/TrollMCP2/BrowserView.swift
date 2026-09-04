import SwiftUI
import WebKit

// v2.9.37：内置浏览器界面（AI 可控，元素蓝框高亮）
struct BrowserView: View {
    @ObservedObject private var bm = BrowserManager.shared
    @State private var urlText = ""
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
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

                // 页面
                WebViewContainer(bm: bm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 状态条
                HStack {
                    Text(bm.pageTitle.isEmpty ? bm.currentURL : "\(bm.pageTitle)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("AI 可用 browser.snapshot 获取蓝框元素")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("内置浏览器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { bm.open("https://www.baidu.com") }) {
                        Text("主页")
                            .font(.footnote)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            bm.ensureWebView()
            if bm.webView?.url == nil || bm.currentURL == "about:blank" {
                bm.open("https://www.baidu.com")
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
