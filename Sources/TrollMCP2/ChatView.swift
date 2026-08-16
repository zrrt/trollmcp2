import SwiftUI

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared

    @State private var inputText = ""
    @State private var reasoning = 1          // 0=低 1=中 2=高
    @State private var smartSearch = true
    @State private var attachmentSheet: AttachmentSheet?
    @State private var showVoiceAlert = false

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
            .navigationTitle(store.currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { withAnimation { AppUIState.shared.drawerOpen.toggle() } }) {
                        Image(systemName: "line.horizontal.3")
                            .font(.system(size: 20, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { store.newConversation() }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
            }
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
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if store.isLoading {
                        HStack {
                            Spacer()
                            TypingIndicator()
                                .padding(.trailing, 16)
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
    @State private var expanded = false

    private var isUser: Bool { message.role == "user" }
    private var isTool: Bool { message.isTool }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 50) }

            if isTool {
                toolBubble
            } else {
                textBubble
            }

            if !isUser { Spacer(minLength: 50) }
        }
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
        .onTapGesture { withAnimation { expanded.toggle() } }
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
