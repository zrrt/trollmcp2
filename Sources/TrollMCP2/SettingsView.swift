import SwiftUI

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    // v2.9.72：开发者模式开关，开启后显示高级选项
    @State private var developerMode = UserDefaults.standard.bool(forKey: "developer_mode")
    // v2.9.76：语言选择弹窗
    @State private var showLanguagePicker = false
    // v2.9.84：聊天框「在设置中管理模型」→ 打开设置并自动跳到模型 API 页
    @State private var jumpToModels = false

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: L10n.t("sec_models"))) {
                    SettingRow(
                        title: L10n.t("row_model_api"),
                        subtitle: "\(ModelStore.shared.configs.count) 个 · \(modelProviderName())",
                        icon: "rectangle.stack.badge.person.crop",
                        color: .blue,
                        destination: ModelsView()
                    )
                    SettingRow(
                        title: L10n.t("row_data"),
                        subtitle: "App 文稿目录",
                        icon: "externaldrive.fill",
                        color: .purple,
                        destination: DataManagementView()
                    )
                    // v2.9.74：系统指令选择器（不可编辑，可切换默认）
                    SettingRow(
                        title: L10n.t("row_sys_prompts"),
                        subtitle: SystemPrompts.shared.selected.name,
                        icon: "text.book.closed.fill",
                        color: .tmCyan,
                        destination: SystemPromptsView()
                    )
                }

                Section(header: SettingSectionHeader(title: L10n.t("sec_core"))) {
                    SettingRow(
                        title: L10n.t("row_inject"),
                        subtitle: L10n.t("row_inject_sub"),
                        icon: "syringe.fill",
                        color: .tmIndigo,
                        destination: InjectionView()
                    )
                    // v2.9.75：远程控制（ControlAgent 通用 UI 控制）
                    SettingRow(
                        title: L10n.t("row_remote"),
                        subtitle: L10n.t("row_remote_sub"),
                        icon: "cursorarrow.click.2",
                        color: .tmCyan,
                        destination: RemoteControlView()
                    )
                    SettingRow(
                        title: L10n.t("row_github"),
                        subtitle: "线上编译 · \(githubAccountSubtitle())",
                        icon: "person.crop.circle.fill.badge.checkmark",
                        color: .black,
                        destination: GitHubAccountView()
                    )
                    SettingRow(
                        title: L10n.t("row_downloads"),
                        subtitle: "线上编译产物 · 勾选删除",
                        icon: "arrow.down.circle.fill",
                        color: .green,
                        destination: DownloadsView()
                    )
                }

                // v2.9.76：开发者模式（美化图标 + 状态色）
                Section {
                    Toggle(isOn: Binding(
                        get: { developerMode },
                        set: { developerMode = $0; UserDefaults.standard.set($0, forKey: "developer_mode") }
                    )) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: developerMode
                                            ? [Color(red: 0.35, green: 0.34, blue: 0.84), Color(red: 0.0, green: 0.74, blue: 0.95)]
                                            : [Color.gray.opacity(0.55), Color.gray.opacity(0.4)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "hammer.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.t("row_dev_mode"))
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(developerMode ? "显示全部高级选项" : "开启后显示开发者选项")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .accentColor(.tmCyan)   // v2.9.76：iOS14 用 accentColor（.tint 需 iOS15+）
                }

                if developerMode {
                    Section(header: SettingSectionHeader(title: L10n.t("sec_dev"))) {
                        // v2.9.82：任务完成通知开关
                        Toggle(isOn: Binding(
                            get: { TaskNotify.shared.enabled },
                            set: { TaskNotify.shared.enabled = $0 }
                        )) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(LinearGradient(colors: [.blue, .tmCyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: "bell.badge.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.t("task_notify"))
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(L10n.t("task_notify_sub"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .accentColor(.tmCyan)
                        // v2.9.76：开发者指令移到开发者模式下面
                        SettingRow(
                            title: L10n.t("row_guide"),
                            subtitle: "7 步流程 · 新手引导",
                            icon: "book.fill",
                            color: .tmCyan,
                            destination: GuideView()
                        )
                        // v2.9.90：图标主题（4 套切换）
                        SettingRow(
                            title: L10n.t("row_icon_theme"),
                            subtitle: "巨魔蓝 · 蓝紫 · 浅白 · 深青",
                            icon: "app.badge.fill",
                            color: .tmCyan,
                            destination: IconThemeView()
                        )
                        // v2.9.90：设备伪装（绿盾式）
                        SettingRow(
                            title: L10n.t("row_device_fake"),
                            subtitle: "伪装机型 · 注入生效",
                            icon: "iphone.gen3.radiowaves.left.and.right",
                            color: .tmCyan,
                            destination: FakeDeviceView()
                        )
                        SettingRow(
                            title: L10n.t("row_dev_instructions"),
                            subtitle: devInstructionsSubtitle(),
                            icon: "doc.text.magnifyingglass",
                            color: .orange,
                            destination: DeveloperInstructionsView()
                        )
                        SettingRow(
                            title: L10n.t("row_permissions"),
                            subtitle: "\(permissionCount()) 项系统权限",
                            icon: "hand.raised.fill",
                            color: .red,
                            destination: SystemCapabilitiesView()
                        )
                        SettingRow(
                            title: L10n.t("row_automation"),
                            subtitle: "任务 · 历史 · 重试",
                            icon: "bolt.fill",
                            color: .yellow,
                            destination: AutomationCenterView()
                        )
                        SettingRow(
                            title: L10n.t("row_tool_policy"),
                            subtitle: "按工具控制 · 真实/占位",
                            icon: "lock.shield.fill",
                            color: .green,
                            destination: ToolPermissionPoliciesView()
                        )
                        SettingRow(
                            title: L10n.t("row_transcripts"),
                            subtitle: "完整对话存档",
                            icon: "text.book.closed.fill",
                            color: .tmCyan,
                            destination: ConversationTranscriptView()
                        )
                        SettingRow(
                            title: L10n.t("row_ssh"),
                            subtitle: sshConfigSubtitle(),
                            icon: "terminal.fill",
                            color: .tmCyan,
                            destination: SSHSettingsView()
                        )
                        SettingRow(
                            title: L10n.t("row_search"),
                            subtitle: "Bing Web · 用法说明",
                            icon: "magnifyingglass.circle.fill",
                            color: .tmCyan,
                            destination: SmartSearchView()
                        )
                        // v2.9.39：内置浏览器改为悬浮窗
                        SettingRowButton(
                            title: L10n.t("row_browser"),
                            subtitle: "悬浮窗 · AI 可控制 · 蓝框高亮",
                            icon: "globe.asia.australia.fill",
                            color: .tmCyan
                        ) {
                            presentationMode.wrappedValue.dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                FloatingBrowser.shared.show()
                            }
                        }
                        SettingRow(
                            title: L10n.t("row_gateway"),
                            subtitle: "服务端管理 · \(GatewayServerStore.shared.servers.count) 个",
                            icon: "network",
                            color: .tmTeal,
                            destination: GatewaySettingsView()
                        )
                        SettingRow(
                            title: L10n.t("row_agents"),
                            subtitle: "隔离指令 · 工作流",
                            icon: "person.3.fill",
                            color: .pink,
                            destination: AgentsAndSkillsView()
                        )
                        SettingRow(
                            title: L10n.t("row_kb"),
                            subtitle: "文件导入 · 来源检索",
                            icon: "books.vertical.fill",
                            color: .tmBrown,
                            destination: KnowledgeBaseView()
                        )
                        SettingRow(
                            title: L10n.t("row_webhooks"),
                            subtitle: "HTTPS 事件出口",
                            icon: "link.circle.fill",
                            color: .gray,
                            destination: WebhooksView()
                        )
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("sec_security"))) {
                    // v2.9.36：本机工具审计（老 MCP 样式：执行成功/失败 · 权限 · 耗时 · 数据量 · 可导出）
                    SettingRow(
                        title: L10n.t("row_audit"),
                        subtitle: "工具调用 · 成功/失败 · 导出给 AI 查看",
                        icon: "list.bullet.rectangle",
                        color: .tmIndigo,
                        destination: AuditLogView()
                    )
                    SettingRow(
                        title: L10n.t("row_apikeys"),
                        subtitle: "查看 · 显隐 · 恢复",
                        icon: "key.fill",
                        color: .red,
                        destination: APIKeyRecoverySheet()
                    )
                }

                Section(header: SettingSectionHeader(title: L10n.t("sec_about"))) {
                    // v2.9.89：关于作者（作者卡片 / 致谢 / 安全 / 赞助 / 反馈）
                    SettingRow(
                        title: L10n.t("about_title"),
                        subtitle: "ZeenAE · 独立开发者",
                        icon: "person.crop.circle.fill",
                        color: .blue,
                        destination: AboutAuthorView()
                    )
                    // v2.9.76：语言切换
                    SettingRowButton(
                        title: L10n.t("row_lang"),
                        subtitle: LanguageManager.shared.language.displayName,
                        icon: "globe",
                        color: .tmCyan
                    ) {
                        showLanguagePicker = true
                    }
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
                    SettingRow(
                        title: L10n.t("row_env"),
                        subtitle: envSubtitle(),
                        icon: envIcon(),
                        color: envColor(),
                        destination: DeviceDetectionView()
                    )
                    SettingRow(
                        title: L10n.t("row_netlog"),
                        subtitle: NetworkLog.lastCompatNote ?? "中转站自适应降级记录",
                        icon: "network",
                        color: .orange,
                        destination: NetworkDebugView()
                    )
                    LabeledRow(label: L10n.t("version"), value: "2.9.104")
                    // v2.9.68：自动更新检查
                    SettingRowButton(
                        title: L10n.t("row_check_update"),
                        subtitle: updateSubtitle(),
                        icon: "arrow.triangle.2.circlepath.circle.fill",
                        color: .tmCyan
                    ) {
                        UpdateManager.shared.checkForUpdate(currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.9.89")
                    }
                    if UpdateManager.shared.updateAvailable, let latest = UpdateManager.shared.latestVersion {
                        SettingRowButton(
                            title: "下载并安装 v\(latest)",
                            subtitle: "点击后调起 TrollStore 安装",
                            icon: "square.and.arrow.down.fill",
                            color: .green
                        ) {
                            UpdateManager.shared.downloadAndInstall()
                        }
                    }
                    LabeledRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "-")
                    LabeledRow(label: "工作区", value: Workspace.root.lastPathComponent)
                    LabeledRow(label: "工具数", value: "\(ToolRegistry.shared.definitions.count)")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v2.9.76：全屏下左侧返回（去掉右上角"完成"）
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { triggerProbe() }   // v2.9.18：进入设置页自动探测一次，更新环境状态色
        // v2.9.84：从聊天框「在设置中管理模型」跳入时自动导航到模型 API 页
        .background(
            NavigationLink(destination: ModelsView(), isActive: $jumpToModels) { EmptyView() }
        )
        .onAppear {
            if AppUIState.shared.settingsJumpToModels {
                AppUIState.shared.settingsJumpToModels = false
                jumpToModels = true
            }
        }
    }

    @State private var lastProbe: DeviceProbe.Report?

    private func envSubtitle() -> String {
        guard let r = lastProbe else { return "TrollStore · 权限 · 注入二进制" }
        if r.ready { return "就绪 · 全部通过" }
        let failed = r.checks.filter { !$0.passed }.count
        return "未就绪 · \(failed) 项异常"
    }

    private func envIcon() -> String {
        // v2.9.76：美化图标（盾牌+对勾/感叹号，随状态变化）
        guard let r = lastProbe else { return "checkmark.shield.fill" }
        if r.ready { return "checkmark.shield.fill" }
        return "exclamationmark.shield.fill"
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

    // v2.9.68：SSH 配置状态
    private func sshConfigSubtitle() -> String {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "ssh_host") ?? ""
        let user = defaults.string(forKey: "ssh_user") ?? ""
        if !host.isEmpty && !user.isEmpty {
            return "\(user)@\(host)"
        }
        return "未配置 · Linux 远程命令"
    }

    // v2.9.68：更新状态
    private func updateSubtitle() -> String {
        if UpdateManager.shared.isChecking { return "正在检查..." }
        if UpdateManager.shared.updateAvailable, let v = UpdateManager.shared.latestVersion {
            return "发现新版本 v\(v)"
        }
        if let error = UpdateManager.shared.errorMessage {
            return "检查失败: \(error.prefix(30))"
        }
        return "当前 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.9.89") · 点击检查"
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
            Section(header: Text("连接信息")) {
                HStack {
                    Text("主机地址").frame(width: 80, alignment: .leading)
                    TextField("如 192.168.1.100", text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text("端口").frame(width: 80, alignment: .leading)
                    TextField("22", text: $port)
                        .keyboardType(.numberPad)
                }
                HStack {
                    Text("用户名").frame(width: 80, alignment: .leading)
                    TextField("如 root", text: $user)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section(header: Text("认证方式（二选一）")) {
                HStack {
                    Text("密码").frame(width: 80, alignment: .leading)
                    SecureField("密码", text: $password)
                }
                HStack {
                    Text("私钥路径").frame(width: 80, alignment: .leading)
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

            Section(header: Text("使用说明")) {
                Text("配置后，AI 可通过 ssh.exec 工具在远程 Linux 服务器执行命令，通过 ssh.scp 传输文件。适用于线上编译、服务器管理、文件同步等场景。")
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
