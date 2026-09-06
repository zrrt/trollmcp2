import SwiftUI

// v2.9.75：远程控制设置页面
// ControlAgent 通用 UI 控制的使用说明和状态展示
// v2.9.77：界面美化——PageHeader + 卡片化 + 双语

struct RemoteControlView: View {
    @State private var connectionStatus: String = L10n.t("status_disconnected")
    @State private var isChecking = false
    @State private var appInfo: String = ""

    var body: some View {
        PageContainer {
            PageHeader(
                icon: "cursorarrow.click.2",
                title: L10n.t("page_remote"),
                subtitle: L10n.t("page_remote_sub"),
                colors: [.tmCyan, .blue]
            )

            // 连接状态卡
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(0.15))
                                .frame(width: 34, height: 34)
                            Circle()
                                .stroke(statusColor.opacity(0.4), lineWidth: 2)
                                .frame(width: 34, height: 34)
                            Image(systemName: isChecking ? "arrow.triangle.2.circlepath" : (connectionStatus == L10n.t("status_connected") ? "checkmark" : "xmark"))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(statusColor)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ControlAgent")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(connectionStatus)
                                .font(.caption)
                                .foregroundColor(statusColor)
                        }
                        Spacer()
                        Button(action: checkConnection) {
                            HStack(spacing: 6) {
                                if isChecking {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Text(isChecking ? "" : L10n.t("btn_check_connection"))
                                    .font(.footnote)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.tmCyan.opacity(0.15))
                            .foregroundColor(.tmCyan)
                            .cornerRadius(10)
                        }
                        .disabled(isChecking)
                    }
                    if !appInfo.isEmpty {
                        Divider()
                        HStack {
                            Text("Bundle ID")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(appInfo)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                    Divider()
                    Text("127.0.0.1:4789 · localhost only")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // 能力
            CardSectionHeader(icon: "sparkles", title: L10n.t("page_remote_sub"))
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    capabilityRow("tree", "读取完整 UI 树（frame / 文字 / 类型 / 无障碍信息）")
                    capabilityRow("camera", "实时截图")
                    capabilityRow("hand.tap", "模拟点击 / 滑动 / 输入文字")
                    capabilityRow("keyboard", "模拟按键（Home / 返回 / 回车）")
                    capabilityRow("checkmark.circle", "通用 UIKit API，不依赖具体 App")
                }
            }

            // 使用流程
            CardSectionHeader(icon: "list.number", title: "使用流程")
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    stepView(1, "在聊天中让 AI 注入：\"给微信注入控制代理\"")
                    stepView(2, "AI 调用 control.inject(bundle_id) 注入 ControlAgent.dylib")
                    stepView(3, "手动启动目标 App（注入后需重启）")
                    stepView(4, "AI 调用 control.status 确认连接")
                    stepView(5, "AI 自动读取 UI 树 → 决定操作 → 点击/输入/滑动")
                }
            }

            // 工具列表
            CardSectionHeader(icon: "wrench.and.screwdriver", title: "工具列表")
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    toolRow("control.inject", "注入 ControlAgent 到目标 App")
                    toolRow("control.status", "检查连接状态")
                    toolRow("control.ui_tree", "读取 UI 树")
                    toolRow("control.screenshot", "截图保存到工作区")
                    toolRow("control.tap", "模拟点击 (x, y)")
                    toolRow("control.swipe", "模拟滑动 (x1,y1 → x2,y2)")
                    toolRow("control.type", "输入文字")
                    toolRow("control.key", "模拟按键 (home/back/enter)")
                }
            }

            // 注意事项
            CardSectionHeader(icon: "exclamationmark.triangle", title: "注意事项", color: .orange)
            CardBox {
                VStack(alignment: .leading, spacing: 6) {
                    noteRow("只监听 localhost (127.0.0.1:4789)，不暴露到网络")
                    noteRow("注入后必须重启目标 App，ControlAgent 才会启动")
                    noteRow("一次只能控制一个前台 App")
                    noteRow("需要 TrollStore 开启\"编辑 Entitlements\"并卸载重装")
                    noteRow("UI 树限制 500 节点、深度 12 层")
                }
            }
        }
        .navigationTitle(L10n.t("page_remote"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusColor: Color {
        if isChecking { return .orange }
        return connectionStatus == L10n.t("status_connected") ? .green : .secondary
    }

    private func stepView(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(num)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func toolRow(_ name: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.tmCyan)
                .frame(width: 120, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func capabilityRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.tmCyan)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func noteRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.orange)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func checkConnection() {
        isChecking = true
        connectionStatus = L10n.t("status_checking")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ControlAgentTools.shared.status()
            DispatchQueue.main.async {
                isChecking = false
                if result["connected"] as? Bool == true {
                    connectionStatus = L10n.t("status_connected")
                    appInfo = (result["app"] as? String) ?? (result["app_name"] as? String) ?? ""
                } else {
                    connectionStatus = L10n.t("status_disconnected")
                    appInfo = ""
                }
            }
        }
    }
}
