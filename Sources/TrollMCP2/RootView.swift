import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            homeTab
                .tabItem { Label("首页", systemImage: "house.fill") }
            ChatView()
                .tabItem { Label("会话", systemImage: "message.fill") }
            ToolsView()
                .tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
            InjectionView()
                .tabItem { Label("注入", systemImage: "syringe") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }

    private var homeTab: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "核心")) {
                    SettingRow(
                        title: "会话",
                        subtitle: "与模型对话",
                        icon: "message.fill",
                        color: .green,
                        destination: ChatView()
                    )
                    SettingRow(
                        title: "操作",
                        subtitle: "待批准 · 运行中 · 最近活动",
                        icon: "circle.grid.cross.fill",
                        color: .orange,
                        destination: OperationView()
                    )
                    SettingRow(
                        title: "助手角色",
                        subtitle: "系统提示词 · 关联模型 · \(AssistantProfileStore.shared.profiles.count) 个",
                        icon: "person.crop.rectangle.stack.fill",
                        color: .pink,
                        destination: AssistantProfilesView()
                    )
                    SettingRow(
                        title: "模型",
                        subtitle: "API 配置 · \(ModelStore.shared.configs.count) 个",
                        icon: "cpu.fill",
                        color: .purple,
                        destination: ModelsView()
                    )
                }

                Section(header: SettingSectionHeader(title: "开发工具")) {
                    SettingRow(
                        title: "注入",
                        subtitle: "已安装 App · dylib 管理",
                        icon: "syringe.fill",
                        color: .red,
                        destination: InjectionView()
                    )
                    SettingRow(
                        title: "编译模式",
                        subtitle: "IPA / dylib · 本地编译",
                        icon: "hammer.fill",
                        color: .orange,
                        destination: BuildView()
                    )
                    SettingRow(
                        title: "系统能力",
                        subtitle: "通讯录 · 日历 · 定位 · 通知",
                        icon: "gearshape.2.fill",
                        color: .blue,
                        destination: SystemCapabilitiesView()
                    )
                }

                Section(header: SettingSectionHeader(title: "连接与自动化")) {
                    SettingRow(
                        title: "网关",
                        subtitle: "WebSocket 配对 · 远程调用",
                        icon: "network",
                        color: .tmIndigo,
                        destination: GatewayView()
                    )
                    SettingRow(
                        title: "自动化中心",
                        subtitle: "任务 · 历史 · 重试",
                        icon: "bolt.fill",
                        color: .yellow,
                        destination: AutomationCenterView()
                    )
                    SettingRow(
                        title: "会话记录",
                        subtitle: "完整对话存档",
                        icon: "text.book.closed.fill",
                        color: .tmCyan,
                        destination: ConversationTranscriptView()
                    )
                    SettingRow(
                        title: "审计日志",
                        subtitle: "操作记录 · 安全审计",
                        icon: "doc.text.magnifyingglass",
                        color: .gray,
                        destination: AuditLogView()
                    )
                }

                Section(header: SettingSectionHeader(title: "更多")) {
                    SettingRow(
                        title: "MCP 工具清单",
                        subtitle: "\(ToolRegistry.shared.definitions.count) 个已注册工具",
                        icon: "wrench.and.screwdriver.fill",
                        color: .tmTeal,
                        destination: ToolsView()
                    )
                    SettingRow(
                        title: "设置",
                        subtitle: "版本 · 权限 · 工作区",
                        icon: "gearshape.fill",
                        color: .secondary,
                        destination: SettingsView()
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("TrollMCP 2")
        }
        .navigationViewStyle(.stack)
    }
}
