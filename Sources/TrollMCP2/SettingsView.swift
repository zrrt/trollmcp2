import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "模型")) {
                    SettingRow(
                        title: "模型 API",
                        subtitle: "\(ModelStore.shared.configs.count) 个 · \(modelProviderName())",
                        icon: "rectangle.stack.badge.person.crop",
                        color: .blue,
                        destination: ModelsView()
                    )
                    SettingRow(
                        title: "数据管理",
                        subtitle: "App 文稿目录",
                        icon: "externaldrive.fill",
                        color: .purple,
                        destination: Text("数据管理占位")
                    )
                    SettingRow(
                        title: "开发者指令",
                        subtitle: "已内置 · 215 行",
                        icon: "doc.text.fill",
                        color: .orange,
                        destination: Text("开发者指令占位")
                    )
                }

                Section(header: SettingSectionHeader(title: "调试服务")) {
                    SettingRow(
                        title: "权限与自动化",
                        subtitle: "\(permissionCount()) 项系统权限",
                        icon: "hand.raised.fill",
                        color: .red,
                        destination: SystemCapabilitiesView()
                    )
                    SettingRow(
                        title: "自动化中心",
                        subtitle: "任务 · 历史 · 重试",
                        icon: "bolt.fill",
                        color: .yellow,
                        destination: AutomationView()
                    )
                    SettingRow(
                        title: "工具权限策略",
                        subtitle: "按工具控制",
                        icon: "lock.shield.fill",
                        color: .green,
                        destination: Text("工具权限策略占位")
                    )
                    SettingRow(
                        title: "注入与自动化",
                        subtitle: "全应用 · 策略 · 自动化",
                        icon: "syringe.fill",
                        color: .indigo,
                        destination: InjectionView()
                    )
                }

                Section(header: SettingSectionHeader(title: "连接与扩展")) {
                    SettingRow(
                        title: "内置智能搜索",
                        subtitle: "Bing Web · RSS 回...",
                        icon: "magnifyingglass.circle.fill",
                        color: .cyan,
                        destination: Text("智能搜索占位")
                    )
                    SettingRow(
                        title: "Gateway",
                        subtitle: "配对 · 离线发件箱",
                        icon: "network",
                        color: .teal,
                        destination: GatewayView()
                    )
                    SettingRow(
                        title: "Agents 与 Skills",
                        subtitle: "隔离指令 · 工...",
                        icon: "person.3.fill",
                        color: .pink,
                        destination: Text("Agents 占位")
                    )
                    SettingRow(
                        title: "本机知识库",
                        subtitle: "文件导入 · 来源检索",
                        icon: "books.vertical.fill",
                        color: .brown,
                        destination: Text("知识库占位")
                    )
                    SettingRow(
                        title: "Webhooks",
                        subtitle: "HTTPS 事件出口",
                        icon: "link.circle.fill",
                        color: .gray,
                        destination: Text("Webhooks 占位")
                    )
                }

                Section(header: SettingSectionHeader(title: "关于")) {
                    LabeledRow(label: "版本", value: "2.0.0")
                    LabeledRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "-")
                    LabeledRow(label: "工作区", value: Workspace.root.lastPathComponent)
                    LabeledRow(label: "工具数", value: "\(ToolRegistry.shared.definitions.count)")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
        }
        .navigationViewStyle(.stack)
    }

    private func modelProviderName() -> String {
        ModelStore.shared.defaultConfig?.provider.capitalized ?? "未配置"
    }

    private func permissionCount() -> Int {
        7
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.system(.footnote, design: .monospaced))
        }
    }
}
