import SwiftUI

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared

    @State private var inputText = ""
    @State private var reasoning = 1          // 0=低 1=中 2=高
    @State private var smartSearch = true
    @State private var showAttachmentSheet = false
    @State private var showVoiceAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if modelStore.configs.isEmpty {
                    emptyState
                } else {
                    messageList
                    currentModelBar
                    inputBar
                }
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

                Button(action: { showAttachmentSheet = true }) {
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

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 50) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.blue : (message.isError ? Color.red.opacity(0.15) : Color(.secondarySystemBackground)))
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(18)
            }
            if !isUser { Spacer(minLength: 50) }
        }
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
