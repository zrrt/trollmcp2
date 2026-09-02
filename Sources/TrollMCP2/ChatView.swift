import SwiftUI
import UIKit

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared

    @State private var inputText = ""
    @State private var reasoning = 1          // 0=低 1=中 2=高
    @State private var smartSearch = true
    @State private var attachmentSheet: AttachmentSheet?
    @State private var showVoiceAlert = false

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
        .sheet(item: $attachmentSheet) { sheet in
            switch sheet {
            case .panel:
                AttachmentPanelView { self.attachmentSheet = $0 }
            case .appPicker:
                AppPickerView { app in
                    let text = "[应用: \(app.name) (\(app.bundleId))]"
                    self.inputText = self.inputText.isEmpty ? text : self.inputText + " " + text
                }
            case .photoPicker:
                PhotoPickerView { urls in
                    let paths = urls.map { $0.lastPathComponent }.joined(separator: " ")
                    let text = "[图片: \(paths)]"
                    self.inputText = self.inputText.isEmpty ? text : self.inputText + " " + text
                }
            case .documentPicker:
                DocumentPickerView { urls in
                    let paths = urls.map { $0.lastPathComponent }.joined(separator: " ")
                    let text = "[文件: \(paths)]"
                    self.inputText = self.inputText.isEmpty ? text : self.inputText + " " + text
                }
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
        store.send(text, using: cfg)
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
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack {
                                Spacer()
                                TypingIndicator()
                                    .padding(.trailing, 16)
                            }
                            if let status = store.statusText {
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 16)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: store.currentMessages.count) { _ in
                if let last = store.currentMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var currentModelBar: some View {
        Button(action: { AppUIState.shared.settingsPresented = true }) {
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
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ChatChip(label: "推理强度·\(reasoningLabel())", action: {
                    reasoning = (reasoning + 1) % 3
                })
                ChatChip(label: "智能搜索·\(smartSearch ? "开" : "关")", action: {
                    smartSearch.toggle()
                })
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    TextField("发消息或点麦克风说话", text: $inputText)
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

                Button(action: { showVoiceAlert = true }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue)
                        .clipShape(Circle())
                }

                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(inputText.isEmpty || store.isLoading ? Color.gray : Color.blue)
                        .clipShape(Circle())
                }
                .disabled(inputText.isEmpty || store.isLoading)
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        // 分享面板挂在常驻输入区上，与附件面板（挂在 NavigationView 上）分离，
        // 避免 iOS 14 同一视图挂多个 sheet 互相覆盖。
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [shareText])
        }
    }

    private func reasoningLabel() -> String {
        ["低", "中", "高"][reasoning]
    }

    private func send() {
        guard let cfg = modelStore.defaultConfig, !inputText.isEmpty else { return }
        if store.selectedId == nil { store.newConversation() }
        let text = inputText
        inputText = ""
        store.send(text, using: cfg)
        AuditLog.shared.log("chat", detail: "发送消息")
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

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground))
                .foregroundColor(.secondary)
                .cornerRadius(12)
        }
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
