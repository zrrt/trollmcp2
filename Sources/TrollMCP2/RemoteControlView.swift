import SwiftUI

// v2.9.75：远程控制设置页面
// ControlAgent 通用 UI 控制的使用说明和状态展示

struct RemoteControlView: View {
    @State private var connectionStatus: String = "未连接"
    @State private var isChecking = false
    @State private var appInfo: String = ""

    var body: some View {
        List {
            Section(header: Text("ControlAgent 通用 UI 控制")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "cursorarrow.click.2")
                            .font(.title2)
                            .foregroundColor(.tmCyan)
                        Text("注入 ControlAgent.dylib 到任意 App 后，AI 可以通过 localhost HTTP 控制目标 App 的 UI")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("能力")
                            .font(.headline)
                        Label("读取完整 UI 树（所有按钮/文本框/列表的 frame、文字、类型）", systemImage: "tree")
                        Label("实时截图", systemImage: "camera")
                        Label("模拟点击/滑动/输入文字", systemImage: "hand.tap")
                        Label("模拟按键（Home/返回/回车）", systemImage: "keyboard")
                        Label("通用 UIKit API，不依赖具体 App", systemImage: "checkmark.circle")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section(header: Text("使用流程")) {
                VStack(alignment: .leading, spacing: 10) {
                    stepView(1, "在聊天中让 AI 注入：\"给微信注入控制代理\"")
                    stepView(2, "AI 调用 control.inject(bundle_id) 注入 ControlAgent.dylib")
                    stepView(3, "手动启动目标 App（注入后需重启）")
                    stepView(4, "AI 调用 control.status 确认连接")
                    stepView(5, "AI 自动读取 UI 树 → 决定操作 → 点击/输入/滑动")
                }
                .padding(.vertical, 8)
            }

            Section(header: Text("连接状态")) {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(connectionStatus)
                        .foregroundColor(connectionStatus == "已连接" ? .green : .secondary)
                }
                if !appInfo.isEmpty {
                    HStack {
                        Text("目标 App")
                        Spacer()
                        Text(appInfo)
                            .foregroundColor(.secondary)
                    }
                }
                Button(action: checkConnection) {
                    HStack {
                        Spacer()
                        if isChecking {
                            ProgressView()
                        } else {
                            Text("检查连接")
                        }
                        Spacer()
                    }
                }
                .disabled(isChecking)
            }

            Section(header: Text("工具列表")) {
                VStack(alignment: .leading, spacing: 6) {
                    toolRow("control.inject", "注入 ControlAgent 到目标 App")
                    toolRow("control.status", "检查连接状态")
                    toolRow("control.ui_tree", "读取 UI 树")
                    toolRow("control.screenshot", "截图保存到工作区")
                    toolRow("control.tap", "模拟点击 (x, y)")
                    toolRow("control.swipe", "模拟滑动 (x1,y1 → x2,y2)")
                    toolRow("control.type", "输入文字")
                    toolRow("control.key", "模拟按键 (home/back/enter)")
                }
                .font(.caption)
                .padding(.vertical, 4)
            }

            Section(header: Text("注意事项")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 只监听 localhost (127.0.0.1:4789)，不暴露到网络")
                    Text("• 注入后必须重启目标 App，ControlAgent 才会启动")
                    Text("• 一次只能控制一个前台 App")
                    Text("• 需要 TrollStore 开启\"编辑 Entitlements\"并卸载重装")
                    Text("• UI 树限制 500 节点、深度 12 层")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .navigationTitle("远程控制")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stepView(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(num)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.tmCyan))
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func toolRow(_ name: String, _ desc: String) -> some View {
        HStack {
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.tmCyan)
            Spacer()
            Text(desc)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func checkConnection() {
        isChecking = true
        connectionStatus = "检查中..."
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ControlAgentTools.shared.status()
            DispatchQueue.main.async {
                isChecking = false
                if result["connected"] as? Bool == true {
                    connectionStatus = "已连接"
                    appInfo = (result["app"] as? String) ?? (result["app_name"] as? String) ?? ""
                } else {
                    connectionStatus = "未连接"
                    appInfo = ""
                }
            }
        }
    }
}
