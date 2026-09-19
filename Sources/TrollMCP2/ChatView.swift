import SwiftUI
import UIKit

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared

    @State private var inputText = ""
    @State private var inputHeight: CGFloat = 20
    // v2.9.234：推理强度/智能搜索持久化(@AppStorage)——之前纯@State,关app重开必丢
    @AppStorage("chat_reasoning") private var reasoning = 0   // 0=低 1=中 2=高
    @AppStorage("chat_smart_search") private var smartSearch = true
    @State private var keyboardHeight: CGFloat = 0   // v2.9.234：键盘高度(消息列表跟随上移)
    @State private var attachmentSheet: AttachmentSheet?
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
                currentModelBar
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
        .sheet(item: $attachmentSheet) { sheet in
            switch sheet {
            case .panel:
                // v2.9.35：传已选数量，面板右上角显示"已选 N"（对齐老 MCP）
                // 紧凑半屏（老 MCP"添加内容"卡片式）；presentationDetents 需 iOS16+
                if #available(iOS 16.0, *) {
                    AttachmentPanelView(onPick: { pick in
                        // v2.9.39：浏览器入口直接开悬浮窗（不占 sheet）
                        if pick == .browser {
                            self.attachmentSheet = nil
                            FloatingBrowser.shared.show()
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
                DocumentPickerView { urls in
                    // v2.9.10：文件选择 → 附件预览
                    for u in urls {
                        self.pendingAttachments.append(PendingAttachment(
                            kind: .file,
                            displayName: u.lastPathComponent,
                            dataURL: nil,
                            thumbnail: nil,
                            bundleId: nil,
                            fileURL: u
                        ))
                    }
                    // v2.9.61：文件预览在预览条显示，不再往输入框塞 [📎文件] 标签
                }
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
        // v2.9.10：网络恢复 / 回前台提示（配合后台自动重连）
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.networkRestored)) { _ in
            showToast("网络已恢复")
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.willEnterForeground)) { _ in
            if AppLifecycleMonitor.shared.isNetworkAvailable {
                showToast("已回到前台")
            }
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
                    miniCard("hammer.fill", L10n.t("home_quick_compile"), L10n.t("home_quick_compile_sub"), [.orange, .tmBrown]) {
                        runQuickPrompt("帮我在 GitHub 上编译一个测试 tweak（HelloWorld），完成后把 dylib 下载到工作区")
                    }
                    miniCard("syringe.fill", L10n.t("home_quick_inject"), L10n.t("home_quick_inject_sub"), [.green, .tmTeal]) {
                        runQuickPrompt("列出本机已安装的应用，选一个测试 dylib 注入并验证加载状态")
                    }
                    miniCard("memorychip.fill", L10n.t("home_quick_memory"), L10n.t("home_quick_memory_sub"), [.purple, .tmIndigo]) {
                        runQuickPrompt("检查内存修改工具（MemoryTweak）是否就绪，并说明用法")
                    }
                    miniCard("cursorarrow.click.2", L10n.t("home_quick_ui"), L10n.t("home_quick_ui_sub"), [.tmCyan, .blue]) {
                        runQuickPrompt("给小红书注入控制代理（ControlAgent），然后读取它的界面树")
                    }
                    miniCard("stethoscope", L10n.t("home_quick_env"), L10n.t("home_quick_env_sub"), [.tmCyan, .teal]) {
                        runQuickPrompt("全面检查本机环境：TrollStore、注入工具链、Entitlements 与网络连通性，输出体检报告")
                    }
                    miniCard("antenna.radiowaves.left.and.right", L10n.t("home_quick_capture"), L10n.t("home_quick_capture_sub"), [.orange, .red]) {
                        runQuickPrompt("对小红书做一次网络抓包分析，列出请求清单和可疑字段")
                    }
                    miniCard("trash.circle.fill", L10n.t("home_quick_clean"), L10n.t("home_quick_clean_sub"), [.purple, .blue]) {
                        runQuickPrompt("扫描本机应用缓存，帮我清理缓存最大的几个 App（先备份再清理）")
                    }
                    miniCard("globe", L10n.t("home_quick_browser"), L10n.t("home_quick_browser_sub"), [.red, .orange]) {
                        runQuickPrompt("打开内置浏览器访问 bing.com，告诉我页面上有什么")
                    }
                    miniCard("bolt.fill", L10n.t("home_quick_automation"), L10n.t("home_quick_automation_sub"), [.blue, .purple]) {
                        runQuickPrompt("帮我创建一个自动化任务：每 5 分钟执行一次 ping，失败时提醒我")
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 24)
            }
            .padding(.top, 16)
        }
    }

    /// v2.9.78：首页能力小卡片（两列网格）
    private func miniCard(_ icon: String, _ title: String, _ subtitle: String, _ colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        store.send(text, using: cfg, reasoningLevel: reasoning, smartSearch: smartSearch)
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
                                .background(Color(.tertiarySystemBackground).opacity(0.9))
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
                        .frame(width: 26, height: 26)
                    Image(systemName: modelIcon(for: currentCfg?.model ?? ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(L10n.t("current_model"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let cfg = currentCfg {
                    Text(cfg.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(cfg.model)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(L10n.t("not_configured"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.tmCyan)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.tmCyan.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            // v2.9.10：待发送附件预览（图片缩略图 / 应用图标 / 文件）
            AttachmentPreviewStrip(attachments: pendingAttachments) { att in
                withAnimation { pendingAttachments.removeAll { $0.id == att.id } }
            }
            HStack(spacing: 8) {
                // v2.9.36：推理强度恒浅蓝；智能搜索开=浅蓝、关=灰（对齐老 MCP）
                // v2.9.79：芯片前置小图标
                ChatChip(label: "推理强度·\(reasoningLabel())", action: {
                    reasoning = (reasoning + 1) % 3
                }, accent: true, icon: "gauge.with.dots.needle.67percent")
                ChatChip(label: "智能搜索·\(smartSearch ? "开" : "关")", action: {
                    smartSearch.toggle()
                }, accent: smartSearch, icon: "magnifyingglass")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    TextEditor(text: $inputText)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 80)
                        .padding(.horizontal, 8)
                        .overlay(
                            ZStack(alignment: .topLeading) {
                                if inputText.isEmpty {
                                    Text("输入消息...")
                                        .font(.system(size: 16))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 16)
                                        .allowsHitTesting(false)
                                }
                                if !inputText.isEmpty {
                                    HStack {
                                        Spacer()
                                        Button(action: { inputText = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 20))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.trailing, 8)
                                    }
                                }
                            }
                        )
                }
                .background(Color.white)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 2)

                Button(action: { attachmentSheet = .panel }) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
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
                attDesc.append("[📎文件：\(att.displayName)] 已保存到 \(sp)，可用 fs.read / fs.hexdump 读取分析")
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
        let finalImgs = attImgs.isEmpty ? imgs : attImgs
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

    // v2.9.169：统一 SharePresenter——修复 contextMenu 收起动画中 present 崩溃
    private func presentShareSheet(text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            showToast("没有可分享的内容")
            return
        }
        SharePresenter.present([content], excluded: [.assignToContact, .print])
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
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
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
    @State private var thinkingExpanded = false

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
            // v2.9.127：执行轨迹（豆包/Codex 式过程流）——历史消息可展开回看
            if !isUser, let trail = message.trail, !trail.isEmpty {
                TrailCard(steps: trail)
            }
            Text(message.content)
                .font(.body)
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

    /// v2.9.20：思考记录（reasoning）折叠视图
    private func thinkingView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { thinkingExpanded.toggle() } }) {
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
            HStack(spacing: 8) {
                Image(systemName: message.isError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 18))
                    .foregroundColor(message.isError ? .red : .green)
                Text(L10n.t("ui_51"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(message.toolName ?? "")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if expanded {
                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
}

/// v2.9.2：系统分享面板（分享到微信/备忘录/邮件等其它 App）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
        .background(Color(.tertiarySystemBackground).opacity(0.85))
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

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: 16)
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.widthTracksTextView = true
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.text = text
        let width = uiView.bounds.width > 10 ? uiView.bounds.width : UIScreen.main.bounds.width - 100
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        height = min(max(size.height, 20), 80)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatInputTextView
        init(_ p: ChatInputTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text ?? ""
            let width = tv.bounds.width > 10 ? tv.bounds.width : UIScreen.main.bounds.width - 100
            let size = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            parent.height = min(max(size.height, 20), 80)
        }
    }
}
