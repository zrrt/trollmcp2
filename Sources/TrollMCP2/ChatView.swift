import SwiftUI
import UIKit

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared

    @State private var inputText = ""
    @State private var reasoning = 1          // 0=低 1=中 2=高
    @State private var smartSearch = true
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
        NavigationView {
            VStack(spacing: 0) {
                if modelStore.configs.isEmpty {
                    emptyState
                } else if store.currentMessages.isEmpty {
                    homeState
                } else {
                    messageList
                }
                currentModelBar
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
                    AttachmentPanelView(onPick: { self.attachmentSheet = $0 }, selectedCount: pendingAttachments.count)
                        .presentationDetents([.height(240)])
                } else {
                    AttachmentPanelView(onPick: { self.attachmentSheet = $0 }, selectedCount: pendingAttachments.count)
                }
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
                    // v2.9.18：不再把长 bundleId 塞进输入框，用简短标记（详情见附件预览条）
                    let text = "[📱应用]"
                    self.inputText = self.inputText.isEmpty ? text : self.inputText + " " + text
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
                    // v2.9.18：图片缩略图在预览条显示，输入框只放简短标记，不再塞文件名
                    if dataURLs.isEmpty {
                        self.pendingImages = []
                        let text = "[🖼图片]"
                        self.inputText = self.inputText.isEmpty ? text : self.inputText + " " + text
                    } else {
                        self.pendingImages = dataURLs
                        let text = "[🖼图片]"
                        self.inputText = self.inputText.isEmpty ? text : self.inputText + " " + text
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
                    // v2.9.18：文件预览在预览条显示，输入框只放简短标记
                    let text = "[📎文件]"
                    self.inputText = self.inputText.isEmpty ? text : self.inputText + " " + text
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
                .presentationDetents([.height(360)])
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
            Text("尚未配置模型")
                .font(.headline)
            Text("请先在设置中添加 API 配置")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var homeState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 40)
                Image(systemName: "cpu")
                    .font(.system(size: 56))
                    .foregroundColor(.blue)
                    .frame(width: 90, height: 90)
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(22)

                VStack(spacing: 8) {
                    Text("你好，我是 TrollMCP")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("在设备端分析应用、内存与签名信息")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    QuickActionCard(
                        icon: "square.grid.2x2",
                        title: "分析我的应用",
                        subtitle: "扫描缓存、注入状态与已安装应用"
                    ) {
                        runQuickPrompt("帮我分析一下本机已安装的应用，列出缓存占用最大的几个")
                    }
                    QuickActionCard(
                        icon: "memorychip",
                        title: "检查设备与内存",
                        subtitle: "设备信息、可用容量与环境检测"
                    ) {
                        runQuickPrompt("检查一下本机设备和内存情况")
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 20)
            }
            .padding(.top, 20)
        }
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
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack {
                                Spacer()
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("正在思考")
                                        .font(.footnote.weight(.medium))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(.tertiarySystemBackground).opacity(0.9))
                                .cornerRadius(14)
                                .padding(.trailing, 16)
                            }
                            if let status = store.statusText {
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 16)
                            }
                            if let tool = store.runningTool {
                                Text("正在执行工具 \(tool)…")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                    .padding(.trailing, 16)
                            }
                            if store.requestRound > 0 {
                                Text("第 \(store.requestRound)/\(store.requestRounds) 轮")
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
        Button(action: { showModelPicker = true }) {
            HStack(spacing: 6) {
                Text("当前模型")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let cfg = modelStore.defaultConfig {
                    Text(cfg.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(cfg.model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("未配置")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            // v2.9.10：待发送附件预览（图片缩略图 / 应用图标 / 文件）
            AttachmentPreviewStrip(attachments: pendingAttachments) { att in
                withAnimation { pendingAttachments.removeAll { $0.id == att.id } }
            }
            HStack(spacing: 8) {
                // v2.9.36：推理强度恒浅蓝；智能搜索开=浅蓝、关=灰（对齐老 MCP）
                ChatChip(label: "推理强度·\(reasoningLabel())", action: {
                    reasoning = (reasoning + 1) % 3
                }, accent: true)
                ChatChip(label: "智能搜索·\(smartSearch ? "开" : "关")", action: {
                    smartSearch.toggle()
                }, accent: smartSearch)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    TextField("发消息…", text: $inputText)
                        .font(.body)
                        .padding(.leading, 12)
                    if !inputText.isEmpty {
                        Button(action: { inputText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .frame(height: 40)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(20)

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
        // v2.9.35：+号面板改挂 sheet（半屏"添加内容"，见 body 外层 .sheet(item:)）
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [shareText])
        }
        // v2.9.30：授权弹窗已移出到 NavigationView 外层（见 body 链），
        // 此处不再挂 actionSheet，避免与上方 +号 的 actionSheet 同 view 覆盖。
    }

    private func reasoningLabel() -> String {
        ["低", "中", "高"][reasoning]
    }

    private func send() {
        guard let cfg = modelStore.defaultConfig, !inputText.isEmpty else { return }
        if store.selectedId == nil { store.newConversation() }
        let text = inputText
        let imgs = pendingImages
        inputText = ""
        pendingImages = []
        // v2.9.10：附件预览与发送联动——从附件里取图片 dataURL（若预览被删则不再发送）
        let attImgs = pendingAttachments.compactMap { $0.dataURL }
        pendingAttachments = []
        let finalImgs = attImgs.isEmpty ? imgs : attImgs
        store.send(text, using: cfg, imageDataURLs: finalImgs, reasoningLevel: reasoning, smartSearch: smartSearch)
        AuditLog.shared.log("chat", detail: "发送消息")
    }

    /// v2.9.9：图片文件 → base64 data URL（限制单张 ≤ 3MB，避免请求体过大）
    static func imageDataURL(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let limit = 3 * 1024 * 1024
        if data.count > limit { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
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
        showShare = true
    }

    private func copySelected() {
        let count = selectedIds.count
        UIPasteboard.general.string = exportText()
        exitSelection()
        showToast(count > 0 ? "已复制 \(count) 条内容" : "已复制")
    }

    private func shareSelected() {
        shareText = exportText()
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

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accent ? Color.blue.opacity(0.14) : Color(.systemGray5))
                .foregroundColor(accent ? Color.blue : Color.secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(accent ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
                )
                .cornerRadius(12)
        }
    }
}

// v2.9.36：聊天框"当前模型"点击弹出的上游模型选择（老 MCP 风格半屏）
struct ChatModelPickerSheet: View {
    @ObservedObject private var modelStore = ModelStore.shared
    let onSelect: (ModelConfig) -> Void

    var body: some View {
        NavigationView {
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
                    Button(action: { AppUIState.shared.settingsPresented = true }) {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(.blue)
                    .frame(width: 44, height: 44)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
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
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
        }
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
            Text(message.content)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser ? Color.blue : (message.isError ? Color.red.opacity(0.15) : Color(.secondarySystemBackground)))
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
                    Text("思考过程")
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
                Text("工具结果")
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
