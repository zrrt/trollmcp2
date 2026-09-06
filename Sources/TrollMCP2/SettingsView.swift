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
                    // v2.9.68：SSH 远程连接
                    SettingRow(
                        title: "SSH 远程连接",
                        subtitle: sshConfigSubtitle(),
                        icon: "terminal.fill",
                        color: .tmCyan,
                        destination: SSHSettingsView()
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
                    LabeledRow(label: "版本", value: "2.9.68")
                    // v2.9.68：自动更新检查
                    SettingRowButton(
                        title: "检查更新",
                        subtitle: updateSubtitle(),
                        icon: "arrow.triangle.2.circlepath.circle.fill",
                        color: .tmCyan
                    ) {
                        UpdateManager.shared.checkForUpdate(currentVersion: "2.9.68")
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
        return "当前 v2.9.68 · 点击检查"
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
