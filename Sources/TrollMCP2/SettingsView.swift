import SwiftUI

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode

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
                        destination: DataManagementView()
                    )
                    SettingRow(
                        title: "开发者指令",
                        subtitle: devInstructionsSubtitle(),
                        icon: "doc.text.fill",
                        color: .orange,
                        destination: DeveloperInstructionsView()
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
                        destination: AutomationCenterView()
                    )
                    SettingRow(
                        title: "工具权限策略",
                        subtitle: "按工具控制 · 真实/占位",
                        icon: "lock.shield.fill",
                        color: .green,
                        destination: ToolPermissionPoliciesView()
                    )
                    SettingRow(
                        title: "注入与自动化",
                        subtitle: "全应用 · 策略 · 自动化",
                        icon: "syringe.fill",
                        color: .tmIndigo,
                        destination: InjectionView()
                    )
                    SettingRow(
                        title: "会话记录",
                        subtitle: "完整对话存档",
                        icon: "text.book.closed.fill",
                        color: .tmCyan,
                        destination: ConversationTranscriptView()
                    )
                }

                Section(header: SettingSectionHeader(title: "连接与扩展")) {
                    SettingRow(
                        title: "GitHub 账号",
                        subtitle: "线上编译 · \(githubAccountSubtitle())",
                        icon: "person.crop.circle.fill.badge.checkmark",
                        color: .black,
                        destination: GitHubAccountView()
                    )
                    SettingRow(
                        title: "下载管理",
                        subtitle: "线上编译产物 · 勾选删除",
                        icon: "arrow.down.circle.fill",
                        color: .green,
                        destination: DownloadsView()
                    )
                    SettingRow(
                        title: "内置智能搜索",
                        subtitle: "Bing Web · 用法说明",
                        icon: "magnifyingglass.circle.fill",
                        color: .tmCyan,
                        destination: SmartSearchView()
                    )
                    // v2.9.39：内置浏览器改为悬浮窗（可缩小到右侧边缘，AI 操作自动浮现）
                    SettingRowButton(
                        title: "内置浏览器",
                        subtitle: "悬浮窗 · AI 可控制 · 蓝框高亮",
                        icon: "globe.asia.australia.fill",
                        color: .tmCyan
                    ) {
                        // 先关设置 sheet，再弹悬浮窗（避免被 sheet 盖住）
                        presentationMode.wrappedValue.dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            FloatingBrowser.shared.show()
                        }
                    }
                    SettingRow(
                        title: "Gateway 设置",
                        subtitle: "服务端管理 · \(GatewayServerStore.shared.servers.count) 个",
                        icon: "network",
                        color: .tmTeal,
                        destination: GatewaySettingsView()
                    )
                    SettingRow(
                        title: "Agents 与 Skills",
                        subtitle: "隔离指令 · 工作流",
                        icon: "person.3.fill",
                        color: .pink,
                        destination: AgentsAndSkillsView()
                    )
                    SettingRow(
                        title: "本机知识库",
                        subtitle: "文件导入 · 来源检索",
                        icon: "books.vertical.fill",
                        color: .tmBrown,
                        destination: KnowledgeBaseView()
                    )
                    SettingRow(
                        title: "Webhooks",
                        subtitle: "HTTPS 事件出口",
                        icon: "link.circle.fill",
                        color: .gray,
                        destination: WebhooksView()
                    )
                }

                Section(header: SettingSectionHeader(title: "安全")) {
                    // v2.9.36：本机工具审计（老 MCP 样式：执行成功/失败 · 权限 · 耗时 · 数据量 · 可导出）
                    SettingRow(
                        title: "本机工具审计",
                        subtitle: "工具调用 · 成功/失败 · 导出给 AI 查看",
                        icon: "list.bullet.rectangle",
                        color: .tmIndigo,
                        destination: AuditLogView()
                    )
                    SettingRow(
                        title: "API Key 管理",
                        subtitle: "查看 · 显隐 · 恢复",
                        icon: "key.fill",
                        color: .red,
                        destination: APIKeyRecoverySheet()
                    )
                }

                Section(header: SettingSectionHeader(title: "关于")) {
                    SettingRow(
                        title: "本机环境检测",
                        subtitle: envSubtitle(),
                        icon: "checkmark.shield.fill",
                        color: envColor(),
                        destination: DeviceDetectionView()
                    )
                    SettingRow(
                        title: "网络兼容日志",
                        subtitle: NetworkLog.lastCompatNote ?? "中转站自适应降级记录",
                        icon: "network",
                        color: .orange,
                        destination: NetworkDebugView()
                    )
                    LabeledRow(label: "版本", value: "2.9.57")
                    LabeledRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "-")
                    LabeledRow(label: "工作区", value: Workspace.root.lastPathComponent)
                    LabeledRow(label: "工具数", value: "\(ToolRegistry.shared.definitions.count)")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { triggerProbe() }   // v2.9.18：进入设置页自动探测一次，更新环境状态色
    }

    @State private var lastProbe: DeviceProbe.Report?

    private func envSubtitle() -> String {
        guard let r = lastProbe else { return "TrollStore · 权限 · 注入二进制" }
        if r.ready { return "就绪 · 全部通过" }
        let failed = r.checks.filter { !$0.passed }.count
        return "未就绪 · \(failed) 项异常"
    }

    private func envColor() -> Color {
        guard let r = lastProbe else { return .green }
        if r.ready { return .green }
        return .orange
    }

    private func triggerProbe() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DeviceProbe.shared.run()
            DispatchQueue.main.async { self.lastProbe = r }
        }
    }

    private func modelProviderName() -> String {
        ModelStore.shared.defaultConfig?.provider.capitalized ?? "未配置"
    }

    private func permissionCount() -> Int {
        7
    }

    private func githubAccountSubtitle() -> String {
        if let login = GitHubAccountStore.shared.activeLogin {
            return "@\(login)"
        }
        return "未登录 · 多账号"
    }

    private func devInstructionsSubtitle() -> String {
        let urls = [
            Bundle.main.url(forResource: "TrollMCPDeveloperInstructions", withExtension: "md"),
            Bundle.main.url(forResource: "TrollMCPDeveloperInstructions", withExtension: "md", subdirectory: "bin"),
        ]
        for url in urls {
            if let url = url, let text = try? String(contentsOf: url, encoding: .utf8) {
                let lines = text.split(separator: "\n").count
                return "已内置 · \(lines) 行"
            }
        }
        return "开发者约定 · 工程指南"
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
