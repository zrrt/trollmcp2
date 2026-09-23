import SwiftUI
import UIKit
import RSKGrowingTextView
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared

    @State private var inputText = ""
    @State private var inputHeight: CGFloat = 36
    // v2.9.234：推理强度/智能搜索持久化(@AppStorage)——之前纯@State,关app重开必丢
    @AppStorage("chat_reasoning") private var reasoning = 0   // 0=低 1=中 2=高
    @AppStorage("chat_smart_search") private var smartSearch = true
    // v3.1.25：思考模型总开关——关闭时完全不思考，直接回复（reasoning_effort=none）
    @AppStorage("chat_think_enabled") private var thinkEnabled = true
    @State private var keyboardHeight: CGFloat = 0   // v2.9.234：键盘高度(消息列表跟随上移)
    @State private var attachmentSheet: AttachmentSheet?
    // v3.1.67：文件选择改用 UIKit UIDocumentPickerViewController（asCopy: true）从顶层 VC present——
    // .fileImporter 在真机 iPhone 上有已知 bug（Apple 论坛 775056：选择器打不开/无法交互/回调不触发），
    // UIKit 方案真机稳定。标记位 + sheet onDismiss 触发，保证面板完全关闭后再 present（不再猜时间延迟）。
    @State private var pendingFilePick = false
    @State private var showModelPicker = false  // v2.9.36：聊天框切换上游模型

    // v2.9.9：多模态图片（data URL）。选择相册图片后转 base64 暂存，发送时随消息传给模型
    @State private var pendingImages: [String] = []
    // v2.9.10：统一待发送附件（图片缩略图 / 应用图标 / 文件），输入栏上方预览
    @State private var pendingAttachments: [PendingAttachment] = []

    // v2.9.2：多选模式（勾选会话内容 → 复制 / 分享到其他 App）
    @State private var selectionMode = false
    @State private var selectedIds = Set<UUID>()
    @State private var showShare = false
    @State private var shareText = ""
    @State private var showToast = false
    @State private var toastText = "已复制"

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                if modelStore.configs.isEmpty {
                    emptyState
                } else if store.currentMessages.isEmpty {
                    homeState
                } else {
                    messageList
                }
                // v2.9.72：工作流可视化步骤条
                WorkflowProgressView()
            }
            // v2.9.244：输入框改用 safeAreaInset 挂底部——标准键盘避让，不再手动 padding 双重压缩内容区
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            .navigationTitle(selectionMode ? "已选 \(selectedIds.count) 条" : store.currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectionMode {
                        Button("取消") { exitSelection() }
                    } else {
                        Button(action: { withAnimation { AppUIState.shared.drawerOpen.toggle() } }) {
                            Image(systemName: "line.horizontal.3")
                                .font(.system(size: 20, weight: .semibold))
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectionMode {
                        HStack(spacing: 14) {
                            Button(action: copySelected) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .disabled(selectedIds.isEmpty)
                            Button(action: shareSelected) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .disabled(selectedIds.isEmpty)
                        }
                    } else {
                        HStack(spacing: 14) {
                            Button(action: enterSelection) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .disabled(store.currentMessages.isEmpty)
                            Button(action: { store.newConversation() }) {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                        }
                    }
                }
            }
            // v2.9.244：删除手动 keyboardHeight padding（会与键盘避让叠加导致内容区被拉高/压缩），键盘避让交给 safeAreaInset
            // v2.9.235：键盘监听仍保留——用于键盘弹出时消息列表滚到底部

            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = h }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
            }
            .overlay(Group {
                if showToast {
                    Text(toastText)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.top, 8)
                }
            }, alignment: .top)
        }
        .navigationViewStyle(.stack)
        // v2.9.31：授权弹窗已整体移除（工具搜索即自动授权，无弹窗）。
        .sheet(item: $attachmentSheet, onDismiss: {
            // v3.1.67：面板完全关闭后再触发文件选择（UIKit 从顶层 VC present，真机稳定）
            // v3.1.70：延迟 0.6s 再 present——onDismiss 触发时 SwiftUI sheet 的关闭动画
            // （约 0.5s）还没完全结束，立即 present 的 UIDocumentPicker 会被 sheet 收尾逻辑
            // 顶掉，表现为"弹出 0.5 秒后自动退回聊天界面"（真机实测 bug）
            if pendingFilePick {
                pendingFilePick = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Self.presentDocumentPicker { urls in
                        handlePickedFiles(urls)
                    }
                }
            }
        }) { sheet in
            switch sheet {
            case .panel:
                // v2.9.35：传已选数量，面板右上角显示"已选 N"（对齐老 MCP）
                // 紧凑半屏（老 MCP"添加内容"卡片式）；presentationDetents 需 iOS16+
                if #available(iOS 16.0, *) {
                    AttachmentPanelView(onPick: { pick in
                        // v2.9.39：浏览器入口直接开悬浮窗（不占 sheet）
                        // v3.1.67：文件入口不再用 .fileImporter（真机有 bug），改记 pendingFilePick，
                        // 由 sheet onDismiss 在面板完全关闭后触发 UIKit 文档选择器
                        if pick == .browser {
                            self.attachmentSheet = nil
                            FloatingBrowser.shared.show()
                        } else if pick == .documentPicker {
                            self.pendingFilePick = true
                            self.attachmentSheet = nil
                        } else {
                            self.attachmentSheet = pick
                        }
                    }, selectedCount: pendingAttachments.count)
                        .sheetDetentsHeight(340)   // v2.9.37：4 入口 2×2 网格需更高
                } else {
                    AttachmentPanelView(onPick: { pick in
                        if pick == .browser {
                            self.attachmentSheet = nil
                            FloatingBrowser.shared.show()
                        } else if pick == .documentPicker {
                            self.pendingFilePick = true
                            self.attachmentSheet = nil
                        } else {
                            self.attachmentSheet = pick
                        }
                    }, selectedCount: pendingAttachments.count)
                }
            case .browser:
                // v2.9.39：浏览器已改为悬浮窗，面板入口在 onPick 闭包里直接开悬浮窗
                EmptyView()
            case .appPicker:
                AppPickerView { app in
                    // v2.9.10：应用选择 → 附件预览（图标 + 名称 + bundleId）
                    let icon = Self.appIcon(for: app.path)
                    let att = PendingAttachment(
                        kind: .app,
                        displayName: app.name,
                        dataURL: nil,
                        thumbnail: icon,
                        bundleId: app.bundleId,
                        fileURL: nil
                    )
                    self.pendingAttachments.append(att)
                    // v2.9.61：不再往输入框塞 [📱应用] 标签，附件只在上方预览条显示（微信风格），发送时自动生成描述
                }
            case .photoPicker:
                PhotoPickerView { urls in
                    // v2.9.9：真正把图片内容转 base64 传给模型（不再只是文件名）
                    var dataURLs: [String] = []
                    var names: [String] = []
                    for u in urls {
                        if let d = Self.imageDataURL(for: u) {
                            dataURLs.append(d)
                            names.append(u.lastPathComponent)
                            // v2.9.10：同时生成带缩略图的附件，输入栏预览
                            let thumb = UIImage(contentsOfFile: u.path)
                            self.pendingAttachments.append(PendingAttachment(
                                kind: .image,
                                displayName: u.lastPathComponent,
                                dataURL: d,
                                thumbnail: thumb,
                                bundleId: nil,
                                fileURL: u
                            ))
                        }
                    }
                    // v2.9.61：图片缩略图在预览条显示，不再往输入框塞 [🖼图片] 标签
                    if dataURLs.isEmpty {
                        self.pendingImages = []
                    } else {
                        self.pendingImages = dataURLs
                    }
                }
            case .documentPicker:
                // v3.1.67：文件选择已改用 UIKit UIDocumentPickerViewController（见 onDismiss + presentDocumentPicker），
                // .fileImporter 在真机 iPhone 有已知 bug，弃用
                EmptyView()
            }
        }
        // v2.9.36：聊天框切换上游模型（点"当前模型"弹出，老 MCP 风格半屏）
        .sheet(isPresented: $showModelPicker) {
            // 老 MCP 半屏；presentationDetents 需 iOS16+
            if #available(iOS 16.0, *) {
                ChatModelPickerSheet { cfg in
                    // 点选即切换默认模型
                    var c = cfg
                    c.isDefault = true
                    modelStore.update(c)
                    showModelPicker = false
                    showToast("已切换：\(cfg.name)")
                }
                .sheetDetentsHeight(360)
            } else {
                ChatModelPickerSheet { cfg in
                    var c = cfg
                    c.isDefault = true
                    modelStore.update(c)
                    showModelPicker = false
                    showToast("已切换：\(cfg.name)")
                }
            }
        }
        // v3.0.76：快捷标签 sheet
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickTerminalPresented }, set: { AppUIState.shared.quickTerminalPresented = $0 })) {
            RemoteTerminalView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickToolsPresented }, set: { AppUIState.shared.quickToolsPresented = $0 })) {
            ToolsView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickSkillsPresented }, set: { AppUIState.shared.quickSkillsPresented = $0 })) {
            AgentsAndSkillsView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickFilesPresented }, set: { AppUIState.shared.quickFilesPresented = $0 })) {
            WorkspaceBrowserView()
        }
        // v2.9.10：网络恢复 / 回前台提示（配合后台自动重连）
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.networkRestored)) { _ in
            showToast("网络已恢复")
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.willEnterForeground)) { _ in
            if AppLifecycleMonitor.shared.isNetworkAvailable {
                showToast("已回到前台")
            }
        }
        // 自定义分享面板（侧载环境下 UIActivityViewController 会闪退）
        .confirmationDialog("分享到...", isPresented: $showShare, titleVisibility: .visible) {
            Button("复制到剪贴板") {
                UIPasteboard.general.string = shareText
                showToast("已复制")
            }
            Button("短信分享") {
                let escaped = shareText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "sms:&body=\(escaped)") {
                    UIApplication.shared.open(url)
                }
            }
            Button("微信分享") {
                // 微信分享到聊天：用 pasteboard 复制后提示用户去微信粘贴
                UIPasteboard.general.string = shareText
                if let url = URL(string: "weixin://") {
                    UIApplication.shared.open(url)
                    showToast("已复制，请在微信粘贴发送")
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选择分享方式")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.badge")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(L10n.t("home_empty_title"))
                .font(.headline)
            Text(L10n.t("home_empty_sub"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var homeState: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 30)
                // v2.9.76：首页使用真实 App 图标（浅蓝巨魔脸）
                // v2.9.78：外层加浅蓝渐变光环
                ZStack {
                    Circle()
                        .fill(Color.tmCyan.opacity(0.12))
                        .frame(width: 176, height: 176)
                    Circle()
                        .stroke(
                            LinearGradient(colors: [.tmCyan.opacity(0.55), .blue.opacity(0.15)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2
                        )
                        .frame(width: 156, height: 156)
                    Group {
                        if let appIcon = UIImage(named: "AppIcon60x60@3x") ?? UIImage(named: "AppIcon1024x1024") {
                            Image(uiImage: appIcon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 104, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                                        .stroke(Color.tmCyan.opacity(0.3), lineWidth: 1)
                                )
                                .shadow(color: Color.tmCyan.opacity(0.35), radius: 14, x: 0, y: 6)
                        } else {
                            Image(systemName: "cpu")
                                .font(.system(size: 56))
                                .foregroundColor(.white)
                                .frame(width: 104, height: 104)
                                .background(
                                    LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .cornerRadius(26)
                        }
                    }
                }

                VStack(spacing: 8) {
                    Text(L10n.t("home_greeting"))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(L10n.t("home_subtitle"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 28)
                }

                // 两大主卡
                VStack(spacing: 12) {
                    QuickActionCard(
                        icon: "square.grid.2x2",
                        title: L10n.t("home_analyze_apps"),
                        subtitle: L10n.t("home_analyze_apps_sub"),
                        colors: [.tmCyan, .blue]
                    ) {
                        runQuickPrompt("帮我分析一下本机已安装的应用，列出缓存占用最大的几个")
                    }
                    QuickActionCard(
                        icon: "memorychip",
                        title: L10n.t("home_check_device"),
                        subtitle: L10n.t("home_check_device_sub"),
                        colors: [.green, .tmTeal]
                    ) {
                        runQuickPrompt("检查一下本机设备和内存情况")
                    }
                }
                .padding(.horizontal, 20)

                // v2.9.78：快速开始引导区（能力卡片，点击即发示例指令）
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.tmCyan)
                        Text(L10n.t("home_quick_title"))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    Text(L10n.t("home_quick_sub"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 22)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    miniCard("hammer.fill", L10n.t("home_quick_compile"), L10n.t("home_quick_compile_sub"), [.orange, .tmBrown], promptId: "developer") {
                        runQuickPrompt("帮我在 GitHub 上编译一个测试 tweak（HelloWorld），完成后把 dylib 下载到工作区")
                    }
                    miniCard("syringe.fill", L10n.t("home_quick_inject"), L10n.t("home_quick_inject_sub"), [.green, .tmTeal], promptId: "reverse") {
                        runQuickPrompt("列出本机已安装的应用，选一个测试 dylib 注入并验证加载状态")
                    }
                    miniCard("memorychip.fill", L10n.t("home_quick_memory"), L10n.t("home_quick_memory_sub"), [.purple, .tmIndigo], promptId: "gamehacker") {
                        runQuickPrompt("检查内存修改工具（MemoryTweak）是否就绪，并说明用法")
                    }
                    miniCard("cursorarrow.click.2", L10n.t("home_quick_ui"), L10n.t("home_quick_ui_sub"), [.tmCyan, .blue], promptId: "uicontrol") {
                        runQuickPrompt("给小红书注入控制代理（ControlAgent），然后读取它的界面树")
                    }
                    miniCard("stethoscope", L10n.t("home_quick_env"), L10n.t("home_quick_env_sub"), [.tmCyan, .teal], promptId: "qa") {
                        runQuickPrompt("全面检查本机环境：TrollStore、注入工具链、Entitlements 与网络连通性，输出体检报告")
                    }
                    miniCard("antenna.radiowaves.left.and.right", L10n.t("home_quick_capture"), L10n.t("home_quick_capture_sub"), [.orange, .red], promptId: "pentester") {
                        runQuickPrompt("对小红书做一次网络抓包分析，列出请求清单和可疑字段")
                    }
                    miniCard("trash.circle.fill", L10n.t("home_quick_clean"), L10n.t("home_quick_clean_sub"), [.purple, .blue], promptId: "privacy") {
                        runQuickPrompt("扫描本机应用缓存，帮我清理缓存最大的几个 App（先备份再清理）")
                    }
                    miniCard("globe", L10n.t("home_quick_browser"), L10n.t("home_quick_browser_sub"), [.red, .orange], promptId: "default") {
                        runQuickPrompt("打开内置浏览器访问 bing.com，告诉我页面上有什么")
                    }
                    miniCard("bolt.fill", L10n.t("home_quick_automation"), L10n.t("home_quick_automation_sub"), [.blue, .purple], promptId: "default") {
                        runQuickPrompt("帮我创建一个自动化任务：每 5 分钟执行一次 ping，失败时提醒我")
                    }
                    miniCard("wrench.and.screwdriver.fill", "一键开发环境", "安装 python3/git/vim/编译工具链", [.green, .blue], promptId: "developer") {
                        runQuickPrompt("帮我用 shell.exec 一键安装基础开发环境：apk add python3 git vim curl build-base")
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 24)
            }
            .padding(.top, 16)
        }
    }

    /// v2.9.78：首页能力小卡片（两列网格）
    /// v3.1.1: 点卡片时自动切换到对应的系统指令模式
    private func miniCard(_ icon: String, _ title: String, _ subtitle: String, _ colors: [Color], promptId: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            // 自动切换到对应的系统指令模式
            if let pid = promptId {
                SystemPrompts.shared.select(pid)
            }
            action()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors[0].opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func runQuickPrompt(_ text: String) {
        guard let cfg = modelStore.defaultConfig else { return }
        if store.selectedId == nil { store.newConversation() }
        inputText = ""
        store.send(text, using: cfg, reasoningLevel: thinkEnabled ? reasoning : 3, smartSearch: smartSearch)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.currentMessages) { msg in
                        MessageBubble(
                            message: msg,
                            selectionMode: selectionMode,
                            isSelected: selectedIds.contains(msg.id),
                            onToggleSelect: { toggleSelect(msg.id) },
                            onCopy: { copyMessage(msg) },
                            onShare: { shareMessage(msg) }
                        )
                        .id(msg.id)
                    }
                    if store.isLoading {
                        // v2.9.34：请求过程可视化（对齐老 MCP 的"正在思考"面板）
                        // v2.9.127：改为实时执行轨迹（豆包工作任务/Codex 式步骤流）
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack {
                                Spacer()
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text(L10n.t("home_thinking"))
                                        .font(.footnote.weight(.medium))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                // v3.1.66：tertiarySystemBackground 浅色模式≈白看不见，改 systemGray5
                                .background(Color(.systemGray5).opacity(0.9))
                                .cornerRadius(14)
                                .padding(.trailing, 16)
                            }
                            if store.isLoading, !store.liveTrail.isEmpty {
                                LiveTrailCard(steps: store.liveTrail)
                                    .padding(.trailing, 16)
                            }
                            if let status = store.statusText {
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 16)
                            }
                            if store.requestRound > 0 {
                                Text(L10n.t("ui_157", store.requestRound, store.requestRounds))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 16)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            // 点击聊天区空白处收起键盘（v2.9.9）
            .simultaneousGesture(
                TapGesture().onEnded { dismissKeyboard() }
            )
            .onChange(of: store.currentMessages.count) { _ in
                if let last = store.currentMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // v2.9.12：打开/切换会话时自动滚到底（老会话不再停在顶部）
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: store.selectedId) { _ in
                scrollToBottom(proxy)
            }
            // v2.9.72：AI 回复完成时结束工作流
            .onChange(of: store.isLoading) { loading in
                if !loading {
                    WorkflowManager.shared.finishRun(success: true)
                }
            }
            // v2.9.235：键盘高度变化→自动滚到底（高度本身由外层 VStack 监听，空会话也能避让键盘）
            .onChange(of: keyboardHeight) { _ in
                if keyboardHeight > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let last = store.currentMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    /// v2.9.12：滚到当前会话最新一条
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if let last = store.currentMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var currentModelBar: some View {
        // v2.9.36：点击"当前模型"弹出模型选择 sheet（不再跳设置），直接切换上游模型
        // v2.9.79：美化——渐变图标 + 胶囊卡片 + 上游模型名
        // v2.9.93：按上游模型供应商换图标
        let currentCfg = modelStore.defaultConfig
        return Button(action: { showModelPicker = true }) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: modelIcon(for: currentCfg?.model ?? ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前模型")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if let cfg = currentCfg {
                        Text(cfg.name)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.tmCyan)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
            // v2.9.10：待发送附件预览（图片缩略图 / 应用图标 / 文件）
            AttachmentPreviewStrip(attachments: pendingAttachments) { att in
                withAnimation { pendingAttachments.removeAll { $0.id == att.id } }
            }
            // v3.0.83：模型选择器居中 80% 宽
            HStack {
                Spacer()
                currentModelBar
                Spacer()
            }
            .padding(.horizontal, 36)
            .padding(.top, 4)

            // v3.0.87：第二行 chips + 快捷标签，等宽填满整行
            HStack(spacing: 6) {
                ChatChip(label: "推理·\(reasoningLabel())", action: {
                    reasoning = (reasoning + 1) % 3
                }, accent: true, icon: "gauge.with.dots.needle.67percent")
                .frame(maxWidth: .infinity)
                ChatChip(label: "思考·\(thinkEnabled ? "开" : "关")", action: {
                    thinkEnabled.toggle()
                }, accent: thinkEnabled, icon: "brain")
                .frame(maxWidth: .infinity)
                ChatChip(label: "搜索·\(smartSearch ? "开" : "关")", action: {
                    smartSearch.toggle()
                }, accent: smartSearch, icon: "magnifyingglass")
                .frame(maxWidth: .infinity)
                QuickTabButton(icon: "bolt", label: "技能") {
                    AppUIState.shared.quickSkillsPresented = true
                }
                .frame(maxWidth: .infinity)
                QuickTabButton(icon: "doc.text", label: "指令") {
                    AppUIState.shared.settingsJumpToModels = false
                    AppUIState.shared.settingsPresented = true
                }
                .frame(maxWidth: .infinity)
                QuickTabButton(icon: "folder", label: "文件") {
                    AppUIState.shared.quickFilesPresented = true
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)

            // v3.0.83：第三行 ish终端图标 + 输入框 + 按钮
            HStack(spacing: 8) {
                Button(action: {
                    AppUIState.shared.quickTerminalPresented = true
                }) {
                    Image(systemName: "terminal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(16)
                }

                HStack(spacing: 0) {
                    ChatInputTextView(text: $inputText, onSend: { send() }, height: $inputHeight)
                        .frame(maxWidth: .infinity)
                        .frame(height: inputHeight)
                        .padding(.horizontal, 10)
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)

                Button(action: { attachmentSheet = .panel }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.blue)
                        .clipShape(Circle())
                }
                // v2.9.35：+号 → 半屏"添加内容"面板（对齐老 MCP 设计），不再用 actionSheet
                // （iOS16 actionSheet 偶发点击无响应 + 无"已选 N"徽标）
                // v2.9.36：移除麦克风按钮（语音无实际作用）

                // v2.9.13：请求中时按钮变为"停止"，点击取消当前请求
                if store.isLoading {
                    Button(action: { store.cancelCurrent() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(inputText.isEmpty ? Color.gray : Color.blue)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.isEmpty)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        // v2.9.30：授权弹窗已移出到 NavigationView 外层（见 body 链），
        // 此处不再挂 actionSheet，避免与上方 +号 的 actionSheet 同 view 覆盖。
    }

    private func reasoningLabel() -> String {
        ["低", "中", "高"][reasoning]
    }

    /// v2.9.93：按模型名识别供应商图标
    private func modelIcon(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("deepseek") { return "d.circle.fill" }
        if m.contains("claude") { return "c.circle.fill" }
        if m.contains("gpt") || m.contains("o1") || m.contains("o3") || m.contains("o4") { return "sparkles" }
        if m.contains("glm") || m.contains("qwen") || m.contains("kimi") { return "brain" }
        if m.contains("gemini") { return "sparkle.magnifyingglass" }
        return "cpu"
    }

    private func send() {
        guard let cfg = modelStore.defaultConfig,
              (!inputText.isEmpty || !pendingAttachments.isEmpty || !pendingImages.isEmpty) else { return }
        // v3.1.5: 自动提取关键信息（App 名、bundle id、文件路径等）
        AutoContextExtractor.shared.extract(from: inputText)
        // v3.1.1: 模型不支持视觉时，自动 OCR 识别图片文字，拼到消息里
        var imagesToSend = pendingImages
        if !pendingImages.isEmpty && !cfg.supportsVision {
            // 自动 OCR：把图片文字识别出来，拼到消息里
            var ocrTexts: [String] = []
            for (i, imgData) in pendingImages.enumerated() {
                if let data = Data(base64Encoded: imgData.replacingOccurrences(of: "data:image/png;base64,", with: "").replacingOccurrences(of: "data:image/jpeg;base64,", with: "")) {
                    let tmpPath = NSTemporaryDirectory() + "ocr_\(i).png"
                    try? data.write(to: URL(fileURLWithPath: tmpPath))
                    if let ocrResult = try? OCRImageTool().invoke(["path": tmpPath]),
                       let text = ocrResult["text"] as? String, !text.isEmpty {
                        ocrTexts.append("📷 图片\(i+1) 识别到的文字：\n\(text)")
                    }
                    try? FileManager.default.removeItem(atPath: tmpPath)
                }
            }
            if !ocrTexts.isEmpty {
                inputText = inputText + "\n\n" + ocrTexts.joined(separator: "\n\n")
                imagesToSend = [] // 去掉图片，只发文字
                showToast("🔍 已自动 OCR 识别图片文字")
            }
        }
        // v2.9.72：启动工作流可视化
        WorkflowManager.shared.startRun("处理请求")
        if store.selectedId == nil { store.newConversation() }
        var text = inputText
        let imgs = pendingImages
        // v2.9.61：输入框不再有 [📱应用] 占位标签，发送时自动把应用/文件附件拼成描述文字
        let appAtts = pendingAttachments.filter { if case .app = $0.kind { return true }; return false }
        let fileAtts = pendingAttachments.filter { if case .file = $0.kind { return true }; return false }
        var attDesc: [String] = []
        for att in appAtts {
            let bid = att.bundleId ?? "unknown"
            attDesc.append("[📱应用：\(att.displayName)（\(bid)）]")
        }
        for att in fileAtts {
            // v2.9.291：文件附件自动复制到工作区 uploads/ 并附加路径——
            // 之前只发 [📎文件：xxx] 描述，AI 根本没有文件内容/路径可读，
            // 导致"找不到 .deb"（文件在用户本地文件App里，AI 视野外）
            let saved = Self.saveAttachmentToWorkspace(att)
            if let sp = saved {
                // v3.1.70：去掉"可用 fs.read / fs.hexdump 读取分析"工具残留（用户反馈），
                // 只保留路径——AI 的 fs 工具集本身就能读，无需在消息里提示
                attDesc.append("[📎文件：\(att.displayName)] 已保存到 \(sp)")
            } else {
                attDesc.append("[📎文件：\(att.displayName)]（复制到工作区失败，请手动放入 \(Workspace.root.path)）")
            }
        }
        if !attDesc.isEmpty {
            text = text.isEmpty ? attDesc.joined(separator: " ") : text + " " + attDesc.joined(separator: " ")
        }
        inputText = ""
        pendingImages = []
        // v2.9.10：附件预览与发送联动——从附件里取图片 dataURL（若预览被删则不再发送）
        let attImgs = pendingAttachments.compactMap { $0.dataURL }
        pendingAttachments = []
        let finalImgs = attImgs.isEmpty ? imagesToSend : attImgs
        store.send(text, using: cfg, imageDataURLs: finalImgs, reasoningLevel: reasoning, smartSearch: smartSearch)
        AuditLog.shared.log("chat", detail: "发送消息")
    }

    /// v2.9.9：图片文件 → base64 data URL
    /// v2.9.292：降采样到最长边 1200px + JPEG q60 压缩——之前只限 3MB 不压缩，
    /// 单张原图 base64 可达 2-4MB，历史里每张图每次请求全量重发 → 卡住/超时。
    /// 压缩后单张 ~100-250KB，省 token 且不卡。
    static func imageDataURL(for url: URL) -> String? {
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        let maxDim: CGFloat = 1200
        var out = img
        if max(img.size.width, img.size.height) > maxDim {
            let scale = maxDim / max(img.size.width, img.size.height)
            let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            img.draw(in: CGRect(origin: .zero, size: newSize))
            out = UIGraphicsGetImageFromCurrentImageContext() ?? img
            UIGraphicsEndImageContext()
        }
        guard let data = out.jpegData(compressionQuality: 0.6) else { return nil }
        let limit = 3 * 1024 * 1024
        if data.count > limit { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    /// v2.9.291：把聊天文件附件复制到工作区 uploads/ 目录，返回保存后的绝对路径
    /// - 处理 security-scoped URL（UIDocumentPicker 返回的 URL 需 startAccessing）
    /// - 文件名冲突时追加时间戳，避免覆盖
    static func saveAttachmentToWorkspace(_ att: PendingAttachment) -> String? {
        guard let src = att.fileURL else { return nil }
        var scoped = false
        if src.startAccessingSecurityScopedResource() { scoped = true }
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: src), data.count > 0 else { return nil }
        let uploads = Workspace.root.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        var name = src.lastPathComponent
        if name.isEmpty { name = att.displayName }
        var dest = uploads.appendingPathComponent(name)
        // 重名冲突：追加 -<时间戳>
        if FileManager.default.fileExists(atPath: dest.path) {
            let ts = Int(Date().timeIntervalSince1970)
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            dest = uploads.appendingPathComponent("\(base)-\(ts).\(ext)")
        }
        do {
            try data.write(to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    /// v2.9.10：读取应用图标（用于输入栏附件预览）
    static func appIcon(for path: String) -> UIImage? {
        guard let info = Bundle(path: path)?.infoDictionary,
              let icons = info["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        let p = (path as NSString).appendingPathComponent(last + "@2x.png")
        return UIImage(contentsOfFile: p) ?? UIImage(contentsOfFile: (path as NSString).appendingPathComponent(last + ".png"))
    }

    // MARK: - v3.1.67：UIKit 文档选择器（真机稳定方案，替代 .fileImporter）

    /// 从顶层 VC present UIDocumentPickerViewController（asCopy: true）。
    /// - 真机 iPhone 上 .fileImporter 有已知 bug（Apple 论坛 775056：选择器打不开/无法交互/回调不触发），
    ///   UIKit 方案在真机完全正常（最早版本能打开文件就是用的 UIKit 方案）。
    /// - asCopy: true 让系统把所选文件复制进 App 沙盒，返回的 URL 直接可读、不会失效，
    ///   无需 startAccessingSecurityScopedResource，也彻底绕开"临时 URL 失效"问题。
    static func presentDocumentPicker(onPick: @escaping ([URL]) -> Void) {
        guard let top = Self.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.modalPresentationStyle = .formSheet
        // coordinator 必须被强引用，否则 delegate 回调不触发
        let coordinator = DocumentPickerCoordinator(onPick: onPick)
        picker.delegate = coordinator
        objc_setAssociatedObject(picker, &DocumentPickerCoordinator.assocKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(picker, animated: true)
    }

    /// 找到当前最顶层的 UIViewController（绕开 SwiftUI sheet 层级问题，直接往 key window 上 present）
    private static func topViewController() -> UIViewController? {
        var vc: UIViewController?
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        } else if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        }
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    /// 选择完成：复制到工作区 uploads/（asCopy 已复制进沙盒，这里再落到 uploads 统一管理 + 防重名）
    private func handlePickedFiles(_ urls: [URL]) {
        for u in urls {
            let att = PendingAttachment(
                kind: .file,
                displayName: u.lastPathComponent,
                dataURL: nil,
                thumbnail: nil,
                bundleId: nil,
                fileURL: u
            )
            if let saved = Self.saveAttachmentToWorkspace(att) {
                self.pendingAttachments.append(PendingAttachment(
                    kind: .file,
                    displayName: u.lastPathComponent,
                    dataURL: nil,
                    thumbnail: nil,
                    bundleId: nil,
                    fileURL: URL(fileURLWithPath: saved)
                ))
            } else {
                self.pendingAttachments.append(att)
            }
        }
    }

    // MARK: - 多选 / 复制 / 分享（v2.9.2）

    private func enterSelection() {
        selectionMode = true
        selectedIds = []
    }

    private func exitSelection() {
        selectionMode = false
        selectedIds = []
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func copyMessage(_ m: ChatMessage) {
        UIPasteboard.general.string = m.content
        showToast("已复制")
    }

    private func shareMessage(_ m: ChatMessage) {
        shareText = m.content
        presentShareSheet(text: m.content)
    }

    private func copySelected() {
        let count = selectedIds.count
        UIPasteboard.general.string = exportText()
        exitSelection()
        showToast(count > 0 ? "已复制 \(count) 条内容" : "已复制")
    }

    private func shareSelected() {
        let text = exportText()
        shareText = text
        presentShareSheet(text: text)
    }

    // v2.9.179：分享面板在侧载环境下会系统级 Segfault（MobileIcons/CoreImage）
    // 改成自定义分享 ActionSheet，列出常用分享目标
    private func presentShareSheet(text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            showToast("没有可分享的内容")
            return
        }
        shareText = content
        showShare = true
    }

    /// 把勾选的消息拼成可读文本（按会话内顺序），用于复制 / 分享。
    private func exportText() -> String {
        let msgs = store.currentMessages.filter { selectedIds.contains($0.id) }
        guard !msgs.isEmpty else { return "" }
        var parts: [String] = []
        let title = store.currentTitle
        if !title.isEmpty && title != "新会话" {
            parts.append("【\(title)】")
        }
        for m in msgs {
            parts.append(formatted(m))
        }
        return parts.joined(separator: "\n\n")
    }

    private func formatted(_ m: ChatMessage) -> String {
        switch m.role {
        case "user":
            return "我：\(m.content)"
        case "tool":
            let name = m.toolName.map { "（\($0)）" } ?? ""
            return "工具结果\(name)：\(m.content)"
        default:
            return m.content
        }
    }

    private func showToast(_ text: String) {
        toastText = text
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { showToast = false }
        }
    }
}

struct ChatChip: View {
    let label: String
    let action: () -> Void
    // v2.9.36：浅蓝=开启/强调，灰=关闭（老 MCP 风格）
    var accent: Bool = true
    // v2.9.79：前置小图标（推理强度 / 智能搜索）
    var icon: String = ""

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .padding(.horizontal, 8)
            .background(accent ? Color.blue.opacity(0.14) : Color(.systemGray5))
            .foregroundColor(accent ? Color.blue : Color.secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accent ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v3.0.76：输入框上方快捷标签按钮
struct QuickTabButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(Color(.secondarySystemBackground))
            .foregroundColor(.secondary)
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v2.9.36：聊天框"当前模型"点击弹出的上游模型选择（老 MCP 风格半屏）
struct ChatModelPickerSheet: View {
    @ObservedObject private var modelStore = ModelStore.shared
    let onSelect: (ModelConfig) -> Void

    var body: some View {
        CompatNav {
            List {
                Section(header: SettingSectionHeader(title: "选择上游模型")) {
                    ForEach(modelStore.configs) { cfg in
                        Button(action: { onSelect(cfg) }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cfg.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("\(cfg.model) · \(cfg.provider)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if cfg.isDefault {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(action: {
                        // v2.9.84：打开设置并直接跳到「模型 API」页
                        AppUIState.shared.settingsJumpToModels = true
                        AppUIState.shared.settingsPresented = true
                    }) {
                        Label("在设置中管理模型", systemImage: "gearshape.fill")
                            .font(.footnote)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("切换模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { }
                        .hidden()
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct QuickActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var colors: [Color] = [.blue, .tmCyan]   // v2.9.78：渐变图标底
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors[0])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(colors[0].opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil

    @State private var expanded = false
    @State private var expandedToolIds: Set<String> = []
    private var thinkingExpanded: Bool {
        expandedToolIds.contains(message.id.uuidString)
    }
    private func toggleThinking() {
        let id = message.id.uuidString
        if expandedToolIds.contains(id) { expandedToolIds.remove(id) }
        else { expandedToolIds.insert(id) }
    }

    private var isUser: Bool { message.role == "user" }
    private var isTool: Bool { message.isTool }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                if selectionMode { selectionBadge }
                Spacer(minLength: 50)
            }

            if isTool {
                toolBubble
            } else {
                textBubble
            }

            if !isUser {
                Spacer(minLength: 50)
                if selectionMode { selectionBadge }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selectionMode {
                onToggleSelect?()
            } else if isTool {
                withAnimation { expanded.toggle() }
            }
        }
        // v2.9.2：长按消息 → 复制 / 分享到其他 App
        .contextMenu {
            Button(action: { onCopy?() }) {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button(action: { onShare?() }) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundColor(isSelected ? .blue : Color.secondary)
            .padding(.bottom, 10)
    }

    private var textBubble: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            // v2.9.10：消息内图片缩略图（用户选择相册图片后，气泡里直接显示图片）
            if let imgs = message.imageDataURLs, !imgs.isEmpty {
                messageImageStrip(imgs)
            }
            // v2.9.20：思考记录（reasoning）可展开显示
            if !isUser, let th = message.thinking, !th.isEmpty {
                thinkingView(th)
            }
            // v3.0.2: 去掉旧的 TrailCard，改用 toolBubble 显示工具调用
            // v3.0.2e：如果 content 是空的，就不显示气泡（避免空白气泡）
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    // v2.9.93：用户气泡改巨魔蓝渐变（浅青→蓝，品牌化），助手保持系统色
                    .background(
                        Group {
                                if isUser {
                                    LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                } else if message.isError {
                                    Color.red.opacity(0.15)
                                } else {
                                    Color(.secondarySystemBackground)
                                }
                            }
                    )
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(isSelected ? (isUser ? Color.white : Color.blue) : Color.clear, lineWidth: 2)
                    )
            }
        }
    }

    /// v2.9.20：思考记录（reasoning）折叠视图
    private func thinkingView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { toggleThinking() } }) {
                HStack(spacing: 6) {
                    Image(systemName: thinkingExpanded ? "chevron.down.circle" : "chevron.right.circle")
                        .font(.system(size: 13))
                    Text(L10n.t("ui_59"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                    Spacer()
                    if thinkingExpanded {
                        Button(action: { UIPasteboard.general.string = text }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            if thinkingExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    /// v2.9.10：data URL → UIImage
    private func messageImageStrip(_ dataURLs: [String]) -> some View {
        let images = dataURLs.compactMap { Self.uiImage(fromDataURL: $0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 140)
                        .cornerRadius(12)
                        .clipped()
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    /// v2.9.10：data URL → UIImage（用于消息气泡图片显示）
    static func uiImage(fromDataURL s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    private var toolBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 📝 1. 思考过程（独立橙色气泡）
            if let thinking = message.thinking, !thinking.isEmpty {
                thinkingMiniBubble(thinking)
            }

            // 🔧✅ 2. 工具调用 + 工具结果（同一个灰色大气泡）
            VStack(alignment: .leading, spacing: 6) {
                        // 工具调用（浅蓝色小气泡，显示工具名 + 命令摘要）
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                        // 显示工具名 + 命令前 60 个字符，一眼就知道在干嘛
                        let displayArgs = (message.toolArgs ?? "").prefix(60)
                        Text("调用工具：\(message.toolName ?? "") \(displayArgs)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                        Spacer()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

                // 工具结果（可折叠）
                toolResultMiniBubble
            }
            .padding(10)
            // v3.1.66：修复"工具气泡浅色模式不显示"——tertiarySystemBackground 在浅色模式≈纯白，
            // 与聊天背景融为一体；改用 secondarySystemBackground（与 AI 回复气泡同色，浅色=浅灰白/深色=深灰）
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
    }

    // 📝 思考过程迷你气泡
    private func thinkingMiniBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { toggleThinking() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text(thinkingExpanded ? "思考过程 ▴" : "思考过程 ▾")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if thinkingExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
            }
        }
    }

    // ✅ 工具结果迷你气泡
    private var toolResultMiniBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: message.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(message.isError ? .red : .green)
                    Text(expanded ? "工具结果 ▴" : "工具结果 ▾")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(message.isError ? .red : .green)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    // v3.1.74：工具结果背景日/夜都改纯黑（用户要求），文字改白色保证黑底可读
                    .foregroundColor(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(.separator), lineWidth: 0.5)
                    )

                // v3.1.6: 工具结果里的文件 → 可点击卡片
                let files = FilePathExtractor.extractFiles(from: message.content)
                if !files.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            FileCardRow(url: url)
                        }
                    }
                }
            }
        }
    }
}

// v3.1.6: 聊天里的文件卡片 —— 点了直接 QuickLook 预览
struct FileCardRow: View {
    let url: URL
    @State private var showPreview = false

    private var fileName: String { url.lastPathComponent }
    private var ext: String { (fileName as NSString).pathExtension.lowercased() }
    private var isImage: Bool { ["png","jpg","jpeg","gif","webp","heic"].contains(ext) }

    private var iconName: String {
        if isImage { return "photo" }
        switch ext {
        case "ipa","tipa": return "shippingbox"
        case "deb","zip","tar","gz": return "archivebox"
        case "dylib","framework": return "hammer"
        case "plist","json": return "doc.text"
        case "pdf": return "doc.richtext"
        case "swift","h","m","c","cpp": return "chevron.left.slash.chevron.right"
        default: return "doc"
        }
    }

    private var sizeText: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        if size > 1024*1024 { return String(format: "%.1f MB", Double(size)/1024/1024) }
        if size > 1024 { return String(format: "%.0f KB", Double(size)/1024) }
        return "\(size) B"
    }

    var body: some View {
        Button(action: { showPreview = true }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.tmCyan.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundColor(.tmCyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(sizeText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundColor(.tmCyan)
            }
            .padding(10)
            // v3.1.66：同 toolBubble——tertiarySystemBackground 浅色模式≈白色看不见，改 systemGray5
            .background(Color(.systemGray5))
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(action: { shareFile() }) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Button(action: { openInTrollStore() }) {
                Label("用 TrollStore 安装", systemImage: "shippingbox")
            }
        }
        .sheet(isPresented: $showPreview) {
            QLFilePreview(urls: [url])
        }
    }

    // 用 UIDocumentInteractionController 分享文件（不枚举图标，避免侧载环境系统级 Segfault）
    private func shareFile() {
        let controller = UIDocumentInteractionController(url: url)
        controller.presentOpenInMenu(from: CGRect(x: 0, y: 0, width: 100, height: 100), in: UIApplication.shared.windows.first ?? UIView(), animated: true)
    }

    // 直接用 TrollStore URL scheme 安装
    private func openInTrollStore() {
        // TrollStore 的 URL scheme 是 trollstore://install?url=...
        // 但本地文件需要先复制到 TrollStore 能访问的位置
        // 这里直接用 OpenIn 菜单让用户选 TrollStore
        shareFile()
    }
}

struct TypingIndicator: View {
    @State private var offset: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundColor(.secondary)
                    .offset(y: offset)
                    .animation(Animation.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.15), value: offset)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
        .onAppear { offset = -4 }
    }
}

// MARK: - v2.9.127 执行轨迹组件（豆包工作任务/Codex 式过程流）

/// 实时轨迹卡片：请求进行中，在"正在思考"下方竖排显示步骤流
struct LiveTrailCard: View {
    let steps: [TrailStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                TrailRow(step: step)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v3.1.66：同 toolBubble——tertiarySystemBackground 浅色模式≈白色看不见，改 systemGray5
        .background(Color(.systemGray5).opacity(0.85))
        .cornerRadius(12)
    }
}

/// 历史轨迹卡片：assistant 消息气泡内，可折叠展开执行全过程
struct TrailCard: View {
    let steps: [TrailStep]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down.circle" : "chevron.right.circle")
                        .font(.system(size: 13))
                    Text(L10n.t("ui_158", steps.count))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.blue)
                    Spacer()
                    Text(summaryText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        TrailRow(step: step)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(12)
    }

    private var summaryText: String {
        let ok = steps.filter { $0.status == .success }.count
        let fail = steps.filter { $0.status == .failed }.count
        if fail > 0 { return "✅\(ok) ❌\(fail)" }
        return "✅ \(ok) 步成功"
    }
}

/// 单步行：图标 + 名称 + 状态色 + 可展开 detail
struct TrailRow: View {
    let step: TrailStep
    @State private var detailExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconFor)
                .font(.system(size: 12))
                .foregroundColor(colorFor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .font(.caption)
                    .fontWeight(step.status == .running ? .medium : .regular)
                    .foregroundColor(step.status == .running ? .primary : (step.status == .failed ? .red : .primary))
                    .lineLimit(1)
                if step.status == .running {
                    Text(L10n.t("ui_64"))
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if !step.detail.isEmpty {
                    if detailExpanded {
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(6)
                            .onTapGesture { detailExpanded = false }
                    } else {
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .onTapGesture { detailExpanded = true }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var iconFor: String {
        switch step.kind {
        case .think: return "brain"
        case .tool: return "wrench.and.screwdriver"
        case .result: return step.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill"
        case .note: return "flag"
        }
    }

    private var colorFor: Color {
        switch step.status {
        case .running: return .blue
        case .success: return .green
        case .failed: return .red
        }
    }
}

// MARK: - v2.9.234 输入框：UITextView 包装(检测 markedText，修复"没打完自动回车")
// SwiftUI TextField 读不到输入法 markedText(拼音未上屏)，iOS16+第三方输入法组合下
// 按回车会直接 submit → 发出去一串拼音。UITextView delegate 可读 markedTextRange：
// 组词中按回车=上屏候选词(return true)，无组词按回车=发送(return false)。

struct ChatInputTextView: UIViewRepresentable {
    @Binding var text: String
    var onSend: () -> Void
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> RSKGrowingTextView {
        let tv = RSKGrowingTextView()
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: 16)
        tv.textColor = UIColor.label
        tv.placeholder = "输入消息..."
        tv.placeholderColor = .gray
        tv.minimumNumberOfLines = 1
        tv.maximumNumberOfLines = 4
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ uiView: RSKGrowingTextView, context: Context) {
        uiView.text = text
        height = uiView.intrinsicContentSize.height
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, RSKGrowingTextViewDelegate {
        var parent: ChatInputTextView
        init(_ p: ChatInputTextView) { parent = p }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.height = textView.intrinsicContentSize.height
        }
    }
}

// MARK: - v3.1.67：UIKit 文档选择器 delegate（真机稳定，替代 .fileImporter）

final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    static var assocKey = "DocumentPickerCoordinatorKey"
    let onPick: ([URL]) -> Void

    init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 用户取消，无操作
    }
}
