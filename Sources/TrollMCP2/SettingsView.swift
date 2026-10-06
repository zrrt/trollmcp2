import SwiftUI
import UIKit

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
    /// v4.3.39：行尾红点（新版提醒等），闭包返回是否显示
    var redDot: (() -> Bool)?
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
    // v4.4.16：底部"指令"胶囊 → 打开设置并自动跳到系统指令(SystemPromptsView)页
    @State private var jumpToSystemPrompts = false
    // v3.3.2：抓包 VPN 开关失败提示
    @State private var vpnToggleError = ""
    // v4.3.29：订阅更新管理器，副标题实时显示 检查中/下载进度/发现新版本
    @ObservedObject private var updateManager = UpdateManager.shared
    // v4.3.30：更新镜像源编辑器
    @State private var showMirrorEditor = false
    @State private var mirrorsText = ""

    var body: some View {
        // v2.9.247：GeometryReader 拿真实全屏尺寸——fullScreenCover+NavigationStack 组合下 List 高度被解析为内容高度(内容不满一屏时列表只占上半屏、下半空白),外层 frame 也无效;改用几何尺寸显式强制 List 与 NavigationStack 铺满全屏,所有机型一致
        GeometryReader { geo in
            CompatNav {
                listBody
                    .frame(minHeight: geo.size.height)
                    .navigationTitle(L10n.t("settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        // v2.9.241：全屏设置页左上角"完成"=关闭设置回聊天
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            Text(L10n.t("done"))
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    // v2.9.245：移除右上角卡片/列表切换按钮——卡片模式在部分机型(iPhone XS等小屏)渲染不稳定(图标/文字显示不全/内容裁剪),统一为列表模式
                }
                // v2.9.234：跳转模型API页——iOS16 navigationDestination(修被弹回), iOS15 NavigationLink兜底
                // v4.4.16：追加"跳系统指令"跳转(底部"指令"胶囊)——与模型跳转对称的 iOS16/iOS15 双兜底
                .background(
                    Group {
                        if #available(iOS 16.0, *) {
                            EmptyView()
                        } else {
                            NavigationLink(destination: ModelsView(), isActive: $jumpToModels) { EmptyView() }.hidden()
                            NavigationLink(destination: SystemPromptsView(), isActive: $jumpToSystemPrompts) { EmptyView() }.hidden()
                        }
                    }
                )
            if #available(iOS 16.0, *) {
                Color.clear.navigationDestination(isPresented: $jumpToModels) { ModelsView() }
                Color.clear.navigationDestination(isPresented: $jumpToSystemPrompts) { SystemPromptsView() }
            }
        }
            .frame(width: geo.size.width, height: geo.size.height)   // NavigationStack 显式全屏
        }
        .navigationViewStyle(.stack)
        .onAppear {
            // v2.9.242：进设置页彻底隐藏悬浮浏览器（不只是收成胶囊），杜绝任何遮挡
            FloatingBrowser.shared.hide()
            triggerProbe()   // v2.9.18：进入设置页自动探测一次，更新环境状态色
        }
        .onAppear {
            if AppUIState.shared.settingsJumpToModels {
                AppUIState.shared.settingsJumpToModels = false
                jumpToModels = true
            }
            // v4.4.16：底部"指令"胶囊 → 跳到系统指令页
            // v4.4.21：延迟一帧触发——iOS16 navigationDestination(isPresented:) 在设置页首帧出现时目标未注册,
            // 立即设 true 会被 SwiftUI 吞掉不跳(用户实测'点指令没真正跳到系统指令页'); 延迟到下一帧目标注册后再跳
            if AppUIState.shared.settingsJumpToSystemPrompts {
                AppUIState.shared.settingsJumpToSystemPrompts = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    jumpToSystemPrompts = true
                }
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
            SettingsItem(title: L10n.t("row_sys_prompts"),
                         subtitle: SystemPrompts.shared.selected.name,
                         icon: "text.book.closed.fill", color: .purple,
                         destination: AnyView(SystemPromptsView()))
        ]))

        // 网络与抓包（v3.3.1：独立分组，不依赖开发者模式——普通用户也能直接看到抓包入口）
        groups.append(SettingsGroup(header: "网络与抓包", items: [
            // v3.3.2：开关 + 点击进详情（Toggle 一键开/关，NavigationLink 进详情页）
            SettingsItem(title: "抓包 VPN",
                         subtitle: vpnActiveSubtitle(),
                         icon: "antenna.radiowaves.left.and.right", color: .tmCyan,
                         destination: AnyView(VpnCaptureView()),
                         isOn: { VpnManager.shared.vpnActive },
                         onToggle: { on in
                             VpnManager.shared.toggleVpn { err in
                                 if let e = err {
                                     DispatchQueue.main.async {
                                         vpnToggleError = e
                                     }
                                 }
                             }
                         }),
            SettingsItem(title: L10n.t("row_netlog"),
                         subtitle: NetworkLog.lastCompatNote ?? "中转站自适应降级记录",
                         icon: "network", color: .orange,
                         destination: AnyView(NetworkDebugView()))
        ]))

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

        // 控制（远程控制/控制中心/操作宏 + 开发者模式开关）
        var controlItems: [SettingsItem] = [
            SettingsItem(title: L10n.t("row_remote"),
                         subtitle: L10n.t("row_remote_sub"),
                         icon: "cursorarrow.click.2", color: .blue,
                         destination: AnyView(RemoteControlView())),
            // v2.9.144：AI 控制中心 + 操作宏（从聊天框移入设置，退出设置页后全屏弹出）
            SettingsItem(title: L10n.t("ui_172"),
                         subtitle: "计划 · 分色日志 · 现场截图 · 操作宏",
                         icon: "target", color: .indigo,
                         action: {
                             presentationMode.wrappedValue.dismiss()
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                 AppUIState.shared.controlPresented = true
                             }
                         })
        ]
        // v4.5.0：可爱助手开关（聊天页右下角悬浮 + 语音/点击互动，可切换角色）
        controlItems.append(SettingsItem(
            title: "可爱助手",
            subtitle: GirlCompanion.shared.enabled ? "运行中 · 聊天页右下角显示" : "关闭 · 聊天页隐藏",
            icon: "heart.fill",
            color: .pink,
            isOn: { GirlCompanion.shared.enabled },
            onToggle: { GirlCompanion.shared.enabled = $0 }
        ))
        // v4.5.1：桌面悬浮 HUD（TrollSpeed 独立二进制，root persona 拉起，手机桌面显示角色）
        controlItems.append(SettingsItem(
            title: "桌面悬浮",
            subtitle: HUDManager.shared.isRunning ? "运行中 · 手机桌面显示" : "未运行 · 手机桌面隐藏",
            icon: "rectangle.on.rectangle",
            color: .purple,
            isOn: { HUDManager.shared.isRunning },
            onToggle: { on in
                if on { _ = HUDManager.shared.start() }
                else { _ = HUDManager.shared.stop() }
            }
        ))
        // v4.5.1：可爱助手角色切换（进入角色选择页，卡片式点选）
        controlItems.append(SettingsItem(
            title: "可爱助手角色",
            subtitle: "当前：\(GirlCompanion.shared.selectedCharacter.rawValue)",
            icon: "person.crop.circle.badge.plus",
            color: .pink,
            destination: AnyView(GirlCharacterPickerView())
        ))
        // v2.9.72：开发者模式开关（固定显示，控制下方"开发者"分组）
        controlItems.append(SettingsItem(
            title: L10n.t("row_dev_mode"),
            subtitle: developerMode ? "显示全部高级选项" : "开启后显示开发者选项",
            icon: "hammer.circle.fill",
            color: developerMode ? .green : .gray,
            isOn: { developerMode },
            onToggle: { on in
                developerMode = on
                UserDefaults.standard.set(on, forKey: "developer_mode")
            }
        ))
        groups.append(SettingsGroup(header: L10n.t("sec_control"), items: controlItems))

        // 开发者
        if developerMode {
            var devItems: [SettingsItem] = [
                SettingsItem(title: L10n.t("task_notify"),
                             subtitle: L10n.t("task_notify_sub"),
                             icon: "bell.badge.fill", color: .blue,
                             isOn: { TaskNotify.shared.enabled },
                             onToggle: { TaskNotify.shared.enabled = $0 }),
                // v4.3.53：图标主题功能彻底移除（含 Resources 残留图标文件）。
                // 侧载环境下动态图标注册可能干扰 MobileIcons 图标缓存（分享面板崩溃嫌疑项）。
                SettingsItem(title: L10n.t("row_device_fake"),
                             subtitle: "伪装机型 · 注入生效",
                             icon: "iphone.gen3.radiowaves.left.and.right", color: .pink,
                             destination: AnyView(FakeDeviceView())),
                SettingsItem(title: L10n.t("row_dev_instructions"),
                             subtitle: devInstructionsSubtitle(),
                             icon: "doc.text.magnifyingglass", color: .orange,
                             destination: AnyView(DeveloperInstructionsView())),
                SettingsItem(title: L10n.t("row_tool_policy"),
                             subtitle: "工具权限 · 系统权限 · 自动化",
                             icon: "lock.shield.fill", color: .green,
                             destination: AnyView(ToolPermissionPoliciesView())),
                SettingsItem(title: L10n.t("row_transcripts"),
                             subtitle: "完整对话存档",
                             icon: "text.book.closed.fill", color: .tmBrown,
                             destination: AnyView(ConversationTranscriptView())),
                SettingsItem(title: "远程访问",
                             subtitle: "SSH 连接远程服务器 · 远程终端被控制",
                             icon: "terminal.fill", color: .teal,
                             destination: AnyView(RemoteAccessView())),
                SettingsItem(title: L10n.t("row_browser"),
                             subtitle: "悬浮窗 · AI 可控制 · 蓝框高亮",
                             icon: "globe.asia.australia.fill", color: .cyan,
                             action: {
                                 presentationMode.wrappedValue.dismiss()
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                     FloatingBrowser.shared.show()
                                 }
                             }),
                SettingsItem(title: L10n.t("row_agents"),
                             subtitle: "隔离指令 · 工作流",
                             icon: "person.3.fill", color: .indigo,
                             destination: AnyView(AgentsAndSkillsView())),
                SettingsItem(title: L10n.t("row_kb"),
                             subtitle: "文件导入 · 来源检索",
                             icon: "books.vertical.fill", color: .brown,
                             destination: AnyView(KnowledgeBaseView()))
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
                         subtitle: "缓存 · 钥匙串 · 广告符 · 数据容器 · 系统清理",
                         icon: "sparkles.rectangle.stack", color: .orange,
                         destination: AnyView(CleanupCenterView())),
            SettingsItem(title: "Coruna 安全盾",
                         subtitle: "检测恶意网站 · 拦截利用 · Web 注入",
                         icon: "shield.lefthalf.filled", color: .green,
                         destination: AnyView(CorunaShieldView())),
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
                         icon: "globe", color: .purple,
                         action: { showLanguagePicker = true }),
            SettingsItem(title: L10n.t("version"),
                         subtitle: ver, icon: "number.circle.fill", color: .gray,
                         destination: nil),
            SettingsItem(title: L10n.t("row_crash"),
                         subtitle: "\(CrashCatcher.list().count) 条闪退记录",
                         icon: "exclamationmark.triangle.fill", color: .red,
                         destination: AnyView(CrashLogView())),
            // v4.3.29：一键更新——单行点击即 检查GitHub最新→下载→调起TrollStore安装
            // v4.3.39：发现新版时行尾显示红点提醒
            SettingsItem(title: L10n.t("row_check_update"),
                         subtitle: updateSubtitle(),
                         icon: "arrow.triangle.2.circlepath.circle.fill", color: .green,
                         action: {
                             updateManager.updateNow(currentVersion: ver)
                         },
                         redDot: { UpdateManager.shared.hasUpdateRedDot }),
            // v4.3.30：多源镜像配置——GitHub 被墙时备用通道
            SettingsItem(title: "更新镜像源",
                         subtitle: mirrorSubtitle(),
                         icon: "arrow.triangle.branch", color: .orange,
                         action: {
                             mirrorsText = UpdateManager.shared.mirrorsText
                             showMirrorEditor = true
                         })
        ]
        groups.append(SettingsGroup(header: L10n.t("sec_about"), items: aboutItems))

        return groups
    }

    // MARK: - 列表模式

    // v4.3.64：已移除 testShareSheet（系统分享面板在本设备侧载环境必崩，无诊断价值）

    private var listBody: some View {
        List {
            // v4.3.64：移除"测试系统分享面板（Debug）"——本设备侧载环境任何系统分享面板
            // 都崩（MobileIcons/CoreImage SIGSEGV，v4.3.43-63 全部真机证伪），
            // 该按钮只会闪退，无诊断价值。分享统一走 ShareCenter 自建菜单（存储到文件/拷贝）。
            ForEach(makeGroups(), id: \.header) { group in
                Section(header: SettingSectionHeader(title: group.header)) {
                    ForEach(group.items) { item in
                        listRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
        .alert("抓包 VPN", isPresented: Binding(
            get: { !vpnToggleError.isEmpty },
            set: { if !$0 { vpnToggleError = "" } }
        )) {
            Button("好", role: .cancel) { vpnToggleError = "" }
        } message: {
            Text(vpnToggleError)
        }
        // v4.3.30：更新镜像源编辑（GitHub 被墙时的备用通道，每行一个前缀，逗号分隔）
        .sheet(isPresented: $showMirrorEditor) {
            NavigationView {
                Form {
                    Section(footer: Text("GitHub 被墙（国内常见）时，自动按顺序尝试这些镜像前缀来检查与下载更新。每行一个，用逗号分隔；留空恢复默认（ghfast.top、gh-proxy.com）。")) {
                        TextEditor(text: $mirrorsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                    }
                }
                .navigationTitle("更新镜像源")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showMirrorEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            UpdateManager.shared.saveMirrors(mirrorsText)
                            showMirrorEditor = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func listRow(_ item: SettingsItem) -> some View {
        // 开关优先：Toggle 项同时带 destination 时用 NavigationLink 包 Toggle（如抓包 VPN 开关）
        if let isOn = item.isOn, let onToggle = item.onToggle {
            let toggle = Toggle(isOn: Binding(get: isOn, set: onToggle)) {
                SettingRowContent(item: item)
            }
            .accentColor(.tmCyan)
            if let dest = item.destination {
                NavigationLink(destination: dest) { toggle }
            } else {
                toggle
            }
        } else if let dest = item.destination {
            NavigationLink(destination: dest) {
                SettingRowContent(item: item)
            }
        } else if let action = item.action {
            Button(action: action) {
                SettingRowContent(item: item)
            }
        } else {
            SettingRowContent(item: item)
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

    // v4.3.29：副标题实时反映更新状态（检查中/下载进度/发现新版本/错误/已是最新）
    // v4.3.30：已是最新时附带检查源（GitHub / jsDelivr / 镜像）
    private func updateSubtitle() -> String {
        let m = updateManager
        if m.isChecking {
            return "正在检查 GitHub 最新构建…"
        }
        if m.isDownloading {
            let pct = Int(m.downloadProgress * 100)
            return "正在下载 v\(m.latestVersion ?? "")… \(pct)%"
        }
        if m.updateAvailable, let v = m.latestVersion {
            return "发现新版本 v\(v) · 点此一键更新安装"
        }
        if let s = m.installMessage, !s.isEmpty {
            return s
        }
        if let e = m.errorMessage, !e.isEmpty {
            return e
        }
        if let s = m.lastSource {
            return "已是最新 · 检查源: \(s)"
        }
        return "已是最新"
    }

    // v4.3.30：镜像源副标题（显示当前生效的镜像，去协议前缀）
    private func mirrorSubtitle() -> String {
        let list = UpdateManager.shared.mirrors
            .map { $0.replacingOccurrences(of: "https://", with: "")
                      .replacingOccurrences(of: "http://", with: "")
                      .replacingOccurrences(of: "/", with: "") }
        return "GitHub 被墙时备用 · " + list.joined(separator: ", ")
    }

    // v3.3.2：抓包 VPN 开关副标题
    private func vpnActiveSubtitle() -> String {
        VpnManager.shared.vpnActive ? "运行中 · 点击右侧开关关闭" : "未运行 · 点击右侧开关开启"
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
            Spacer(minLength: 0)
            // v4.3.39：行尾红点提醒（新版更新等）——红点在行尾右侧，点击行即处理
            if let redDot = item.redDot, redDot() {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
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
