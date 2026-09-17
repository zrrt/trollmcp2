import SwiftUI

// MARK: - 设置项数据（列表/卡片双视图共用，永不脱节）

struct SettingsItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var destination: AnyView?
    var action: (() -> Void)?
    var isOn: (() -> Bool)?
    var onToggle: ((Bool) -> Void)?
}

struct SettingsGroup {
    let header: String
    var items: [SettingsItem]
}

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    // v2.9.72：开发者模式开关，开启后显示高级选项
    // v2.9.234：@AppStorage 持久化——之前 @State 只在创建时读一次,view重建会读到旧值(开发者模式偶发自动关闭)
    @AppStorage("developer_mode") private var developerMode = false
    // v2.9.76：语言选择弹窗
    @State private var showLanguagePicker = false
    // v2.9.84：聊天框「在设置中管理模型」→ 打开设置并自动跳到模型 API 页
    @State private var jumpToModels = false
    // v2.9.144：双视图切换（列表 ↔ 分组卡片），右上角切换，持久化
    @AppStorage("settings.card_mode") private var cardMode = false

    var body: some View {
        CompatNav {
            Group {
                if cardMode {
                    cardBody
                } else {
                    listBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // v2.9.241：外层强制撑满——修复iOS16 NavigationStack+fullScreenCover下内容高度被裁剪(只有中间一小块能滚动/可视范围缩小)
            .navigationTitle(L10n.t("settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // v2.9.241：全屏设置页左上角用"完成"文字（明确=关闭设置回聊天），避免返回箭头被误解为返回上一页
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Text(L10n.t("done"))
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                // v2.9.144：右上角切换展示方式
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { cardMode.toggle() }) {
                        Image(systemName: cardMode ? "list.bullet" : "square.grid.2x2")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel(cardMode ? "切换为列表" : "切换为卡片")
                }
            }
            // v2.9.234：跳转模型API页——iOS16 navigationDestination(修被弹回), iOS15 NavigationLink兜底
            .background(
                Group {
                    if #available(iOS 16.0, *) {
                        EmptyView()
                    } else {
                        NavigationLink(destination: ModelsView(), isActive: $jumpToModels) { EmptyView() }.hidden()
                    }
                }
            )
            if #available(iOS 16.0, *) {
                Color.clear.navigationDestination(isPresented: $jumpToModels) { ModelsView() }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            // v2.9.239：进设置页收起悬浮浏览器，避免遮挡设置项点击
            FloatingBrowser.shared.collapse()
            triggerProbe()   // v2.9.18：进入设置页自动探测一次，更新环境状态色
        }
        .onAppear {
            if AppUIState.shared.settingsJumpToModels {
                AppUIState.shared.settingsJumpToModels = false
                jumpToModels = true
            }
        }
    }

    // MARK: - 数据源（两种视图共用）

    private func makeGroups() -> [SettingsGroup] {
        var groups: [SettingsGroup] = []

        // 模型
        groups.append(SettingsGroup(header: L10n.t("sec_models"), items: [
            SettingsItem(title: L10n.t("row_model_api"),
                         subtitle: "\(ModelStore.shared.configs.count) 个 · \(modelProviderName())",
                         icon: "rectangle.stack.badge.person.crop", color: .blue,
                         destination: AnyView(ModelsView())),
            SettingsItem(title: L10n.t("row_data"),
                         subtitle: "App 文稿目录", icon: "externaldrive.fill", color: .purple,
                         destination: AnyView(DataManagementView())),
            SettingsItem(title: L10n.t("row_sys_prompts"),
                         subtitle: SystemPrompts.shared.selected.name,
                         icon: "text.book.closed.fill", color: .tmCyan,
                         destination: AnyView(SystemPromptsView()))
        ]))

        // 控制（注入/远程控制/控制中心/操作宏 + 开发者模式开关）
        var controlItems: [SettingsItem] = [
            SettingsItem(title: L10n.t("row_inject"),
                         subtitle: L10n.t("row_inject_sub"),
                         icon: "syringe.fill", color: .tmIndigo,
                         destination: AnyView(InjectionView())),
            SettingsItem(title: L10n.t("row_remote"),
                         subtitle: L10n.t("row_remote_sub"),
                         icon: "cursorarrow.click.2", color: .tmCyan,
                         destination: AnyView(RemoteControlView())),
            // v2.9.144：AI 控制中心 + 操作宏（从聊天框移入设置，退出设置页后全屏弹出）
            SettingsItem(title: L10n.t("ui_172"),
                         subtitle: "计划 · 分色日志 · 现场截图",
                         icon: "target", color: .tmCyan,
                         action: {
                             presentationMode.wrappedValue.dismiss()
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                 AppUIState.shared.controlPresented = true
                             }
                         }),
            SettingsItem(title: L10n.t("ui_183"),
                         subtitle: "录制 · 回放 · 导出",
                         icon: "play.rectangle", color: .orange,
                         action: {
                             presentationMode.wrappedValue.dismiss()
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                 AppUIState.shared.macroPresented = true
                             }
                         })
        ]
        // v2.9.72：开发者模式开关（固定显示，控制下方"开发者"分组）
        controlItems.append(SettingsItem(
            title: L10n.t("row_dev_mode"),
            subtitle: developerMode ? "显示全部高级选项" : "开启后显示开发者选项",
            icon: "hammer.circle.fill",
            color: developerMode ? .tmCyan : .gray,
            isOn: { developerMode },
            onToggle: { on in
                developerMode = on
                UserDefaults.standard.set(on, forKey: "developer_mode")
            }
        ))
        groups.append(SettingsGroup(header: L10n.t("sec_control"), items: controlItems))

        // 线上编译
        groups.append(SettingsGroup(header: L10n.t("sec_build"), items: [
            SettingsItem(title: L10n.t("row_github"),
                         subtitle: "线上编译 · \(githubAccountSubtitle())",
                         icon: "person.crop.circle.fill.badge.checkmark", color: .black,
                         destination: AnyView(GitHubAccountView())),
            SettingsItem(title: L10n.t("row_downloads"),
                         subtitle: "线上编译产物 · 勾选删除",
                         icon: "arrow.down.circle.fill", color: .green,
                         destination: AnyView(DownloadsView()))
        ]))

        // 开发者
        if developerMode {
            var devItems: [SettingsItem] = [
                SettingsItem(title: L10n.t("task_notify"),
                             subtitle: L10n.t("task_notify_sub"),
                             icon: "bell.badge.fill", color: .blue,
                             isOn: { TaskNotify.shared.enabled },
                             onToggle: { TaskNotify.shared.enabled = $0 }),
                SettingsItem(title: L10n.t("row_icon_theme"),
                             subtitle: "巨魔蓝 · 蓝紫 · 浅白 · 深青",
                             icon: "app.badge.fill", color: .tmCyan,
                             destination: AnyView(IconThemeView())),
                SettingsItem(title: L10n.t("row_device_fake"),
                             subtitle: "伪装机型 · 注入生效",
                             icon: "iphone.gen3.radiowaves.left.and.right", color: .tmCyan,
                             destination: AnyView(FakeDeviceView())),
                SettingsItem(title: L10n.t("row_dev_instructions"),
                             subtitle: devInstructionsSubtitle(),
                             icon: "doc.text.magnifyingglass", color: .orange,
                             destination: AnyView(DeveloperInstructionsView())),
                SettingsItem(title: L10n.t("row_permissions"),
                             subtitle: "\(permissionCount()) 项系统权限",
                             icon: "hand.raised.fill", color: .red,
                             destination: AnyView(SystemCapabilitiesView())),
                SettingsItem(title: L10n.t("row_automation"),
                             subtitle: "任务 · 历史 · 重试",
                             icon: "bolt.fill", color: .yellow,
                             destination: AnyView(AutomationCenterView())),
                SettingsItem(title: L10n.t("row_tool_policy"),
                             subtitle: "按工具控制 · 真实/占位",
                             icon: "lock.shield.fill", color: .green,
                             destination: AnyView(ToolPermissionPoliciesView())),
                SettingsItem(title: L10n.t("row_transcripts"),
                             subtitle: "完整对话存档",
                             icon: "text.book.closed.fill", color: .tmCyan,
                             destination: AnyView(ConversationTranscriptView())),
                SettingsItem(title: L10n.t("row_ssh"),
                             subtitle: sshConfigSubtitle(),
                             icon: "terminal.fill", color: .tmCyan,
                             destination: AnyView(SSHSettingsView())),
                SettingsItem(title: L10n.t("row_search"),
                             subtitle: "Bing Web · 用法说明",
                             icon: "magnifyingglass.circle.fill", color: .tmCyan,
                             destination: AnyView(SmartSearchView())),
                SettingsItem(title: L10n.t("row_browser"),
                             subtitle: "悬浮窗 · AI 可控制 · 蓝框高亮",
                             icon: "globe.asia.australia.fill", color: .tmCyan,
                             action: {
                                 presentationMode.wrappedValue.dismiss()
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                     FloatingBrowser.shared.show()
                                 }
                             }),
                SettingsItem(title: L10n.t("row_gateway"),
                             subtitle: "服务端管理 · \(GatewayServerStore.shared.servers.count) 个",
                             icon: "network", color: .tmTeal,
                             destination: AnyView(GatewaySettingsView())),
                SettingsItem(title: L10n.t("row_agents"),
                             subtitle: "隔离指令 · 工作流",
                             icon: "person.3.fill", color: .pink,
                             destination: AnyView(AgentsAndSkillsView())),
                SettingsItem(title: L10n.t("row_kb"),
                             subtitle: "文件导入 · 来源检索",
                             icon: "books.vertical.fill", color: .tmBrown,
                             destination: AnyView(KnowledgeBaseView())),
                SettingsItem(title: L10n.t("row_webhooks"),
                             subtitle: "HTTPS 事件出口",
                             icon: "link.circle.fill", color: .gray,
                             destination: AnyView(WebhooksView()))
            ]
            groups.append(SettingsGroup(header: L10n.t("sec_dev"), items: devItems))
        }

        // 安全
        groups.append(SettingsGroup(header: L10n.t("sec_security"), items: [
            SettingsItem(title: L10n.t("row_audit"),
                         subtitle: "工具调用 · 成功/失败 · 导出给 AI 查看",
                         icon: "list.bullet.rectangle", color: .tmIndigo,
                         destination: AnyView(AuditLogView())),
            SettingsItem(title: L10n.t("row_workspace"),
                         subtitle: "点开浏览目录 · 预览 · 复制路径 · 分享",
                         icon: "folder", color: .blue,
                         destination: AnyView(WorkspaceBrowserView())),
            SettingsItem(title: "清理中心",
                         subtitle: "缓存 · 钥匙串 · 广告符 · 数据容器 · AI 清理",
                         icon: "sparkles.rectangle.stack", color: .tmCyan,
                         destination: AnyView(CleanupCenterView())),
            SettingsItem(title: "系统清理",
                         subtitle: "存储使用 · 缓存占用 · 快速/高级清理",
                         icon: "externaldrive.fill.badge.timemachine", color: .red,
                         destination: AnyView(SystemCleanupView())),
            SettingsItem(title: "远程终端",
                         subtitle: "公网 HTTP API · 云端直连调工具/看审计/读崩溃",
                         icon: "terminal.fill", color: .tmCyan,
                         destination: AnyView(RemoteTerminalView())),
        ]))

        // 关于
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var aboutItems: [SettingsItem] = [
            SettingsItem(title: L10n.t("about_title"),
                         subtitle: "ZeenAE · 独立开发者",
                         icon: "person.crop.circle.fill", color: .blue,
                         destination: AnyView(AboutAuthorView())),
            SettingsItem(title: L10n.t("row_lang"),
                         subtitle: LanguageManager.shared.language.displayName,
                         icon: "globe", color: .tmCyan,
                         action: { showLanguagePicker = true }),
            SettingsItem(title: L10n.t("row_env"),
                         subtitle: envSubtitle(),
                         icon: envIcon(), color: envColor(),
                         destination: AnyView(DeviceDetectionView())),
            SettingsItem(title: L10n.t("row_netlog"),
                         subtitle: NetworkLog.lastCompatNote ?? "中转站自适应降级记录",
                         icon: "network", color: .orange,
                         destination: AnyView(NetworkDebugView())),
            SettingsItem(title: L10n.t("version"),
                         subtitle: ver, icon: "number.circle.fill", color: .gray,
                         destination: nil),
            SettingsItem(title: L10n.t("row_crash"),
                         subtitle: "\(CrashCatcher.list().count) 条闪退记录",
                         icon: "exclamationmark.triangle.fill", color: .orange,
                         destination: AnyView(CrashLogView())),
            SettingsItem(title: L10n.t("row_check_update"),
                         subtitle: updateSubtitle(),
                         icon: "arrow.triangle.2.circlepath.circle.fill", color: .tmCyan,
                         action: {
                             UpdateManager.shared.checkForUpdate(currentVersion: ver)
                         })
        ]
        if UpdateManager.shared.updateAvailable, let latest = UpdateManager.shared.latestVersion {
            aboutItems.append(SettingsItem(
                title: "下载并安装 v\(latest)",
                subtitle: "点击后调起 TrollStore 安装",
                icon: "square.and.arrow.down.fill", color: .green,
                action: { UpdateManager.shared.downloadAndInstall() }
            ))
        }
        groups.append(SettingsGroup(header: L10n.t("sec_about"), items: aboutItems))

        return groups
    }

    // MARK: - 列表模式

    private var listBody: some View {
        List {
            ForEach(makeGroups(), id: \.header) { group in
                Section(header: SettingSectionHeader(title: group.header)) {
                    ForEach(group.items) { item in
                        listRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // v2.9.240：修复iOS16 NavigationStack+fullScreenCover下List高度被裁剪(只有中间一小块能滚动)
        .actionSheet(isPresented: $showLanguagePicker) {
            ActionSheet(
                title: Text(L10n.t("row_lang")),
                buttons: AppLanguage.allCases.map { lang in
                    .default(Text(lang.displayName)) {
                        LanguageManager.shared.language = lang
                    }
                } + [.cancel(Text(L10n.t("cancel")))]
            )
        }
    }

    @ViewBuilder
    private func listRow(_ item: SettingsItem) -> some View {
        if let dest = item.destination {
            NavigationLink(destination: dest) {
                SettingRowContent(item: item)
            }
        } else if let isOn = item.isOn, let onToggle = item.onToggle {
            Toggle(isOn: Binding(get: isOn, set: onToggle)) {
                SettingRowContent(item: item)
            }
            .accentColor(.tmCyan)
        } else if let action = item.action {
            Button(action: action) {
                SettingRowContent(item: item)
            }
        } else {
            SettingRowContent(item: item)
        }
    }

    // MARK: - 卡片模式（分组卡片，对齐 Fuck 工具箱"更多"页）

    private var cardBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(makeGroups(), id: \.header) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.header)
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(group.items) { item in
                                card(item)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // v2.9.240：同上，卡片模式也强制撑满
        .actionSheet(isPresented: $showLanguagePicker) {
            ActionSheet(
                title: Text(L10n.t("row_lang")),
                buttons: AppLanguage.allCases.map { lang in
                    .default(Text(lang.displayName)) {
                        LanguageManager.shared.language = lang
                    }
                } + [.cancel(Text(L10n.t("cancel")))]
            )
        }
    }

    @ViewBuilder
    private func card(_ item: SettingsItem) -> some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(item.color.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: item.icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(item.color)
            }
            Text(item.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            if item.isOn != nil, let isOn = item.isOn {
                Toggle("", isOn: Binding(get: isOn, set: item.onToggle ?? { _ in }))
                    .labelsHidden()
                    .scaleEffect(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        if let dest = item.destination {
            NavigationLink(destination: dest) { content }
                .buttonStyle(.plain)
        } else if let action = item.action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    // MARK: - 动态值

    @State private var lastProbe: DeviceProbe.Report?

    private func envSubtitle() -> String {
        if let r = lastProbe {
            let failed = r.checks.filter { !$0.passed }.count
            return r.ready ? "就绪 · 可注入" : "需检查 \(failed) 项"
        }
        return "点击探测"
    }

    private func envIcon() -> String {
        if let r = lastProbe {
            return r.ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
        }
        return "shield.lefthalf.filled"
    }

    private func envColor() -> Color {
        if let r = lastProbe {
            return r.ready ? .green : .red
        }
        return .gray
    }

    // v2.9.144：探测含 spawnRoot/文件遍历，主线程同步会卡死被看门狗杀（表现为闪退）
    private func triggerProbe() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DeviceProbe.shared.run()
            DispatchQueue.main.async {
                self.lastProbe = r
            }
        }
    }

    private func modelProviderName() -> String {
        ModelStore.shared.configs.first(where: { $0.isDefault })?.provider ?? ModelStore.shared.configs.first?.provider ?? "未配置"
    }

    private func permissionCount() -> Int {
        7
    }

    private func githubAccountSubtitle() -> String {
        if let login = GitHubAccountStore.shared.activeLogin {
            return "@\(login)"
        }
        let count = GitHubAccountStore.shared.accounts.count
        return count == 0 ? "未登录 · 多账号" : "\(count) 个账号"
    }

    private func devInstructionsSubtitle() -> String {
        let count = DeveloperInstructionStore.shared.list().count
        return "\(count) 条 · 长按设默认"
    }

    private func sshConfigSubtitle() -> String {
        let host = UserDefaults.standard.string(forKey: "ssh.host") ?? ""
        return host.isEmpty ? "未配置" : host
    }

    private func updateSubtitle() -> String {
        UpdateManager.shared.updateAvailable ? "发现新版本" : "已是最新"
    }
}

/// 行内容（列表/卡片共用视觉）
struct SettingRowContent: View {
    let item: SettingsItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.color)
                    .frame(width: 34, height: 34)
                Image(systemName: item.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .foregroundColor(.primary)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
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

// v2.9.68：SSH 远程连接设置
struct SSHSettingsView: View {
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var keyPath: String = ""
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        Form {
            Section(header: Text(L10n.t("ui_137"))) {
                HStack {
                    Text(L10n.t("ui_20")).frame(width: 80, alignment: .leading)
                    TextField("如 192.168.1.100", text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text(L10n.t("ui_119")).frame(width: 80, alignment: .leading)
                    TextField("22", text: $port)
                        .keyboardType(.numberPad)
                }
                HStack {
                    Text(L10n.t("ui_112")).frame(width: 80, alignment: .leading)
                    TextField("如 root", text: $user)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section(header: Text(L10n.t("ui_131"))) {
                HStack {
                    Text(L10n.t("ui_46")).frame(width: 80, alignment: .leading)
                    SecureField("密码", text: $password)
                }
                HStack {
                    Text(L10n.t("ui_117")).frame(width: 80, alignment: .leading)
                    TextField("可选，如 /var/mobile/.ssh/id_rsa", text: $keyPath)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section {
                Button("保存配置") {
                    let defaults = UserDefaults.standard
                    defaults.set(host, forKey: "ssh_host")
                    defaults.set(Int(port) ?? 22, forKey: "ssh_port")
                    defaults.set(user, forKey: "ssh_user")
                    defaults.set(password, forKey: "ssh_password")
                    defaults.set(keyPath, forKey: "ssh_key_path")
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.blue)
            }

            Section(header: Text(L10n.t("ui_24"))) {
                Text(L10n.t("ui_140"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("SSH 远程连接")
        .onAppear {
            let defaults = UserDefaults.standard
            host = defaults.string(forKey: "ssh_host") ?? ""
            port = "\(defaults.integer(forKey: "ssh_port") == 0 ? 22 : defaults.integer(forKey: "ssh_port"))"
            user = defaults.string(forKey: "ssh_user") ?? ""
            password = defaults.string(forKey: "ssh_password") ?? ""
            keyPath = defaults.string(forKey: "ssh_key_path") ?? ""
        }
    }
}
