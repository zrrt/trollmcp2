import SwiftUI

struct ChatView: View {
    @StateObject private var conversation = ConversationStore()
    @State private var inputText = ""
    @ObservedObject private var modelStore = ModelStore.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if modelStore.configs.isEmpty {
                    emptyState
                } else {
                    messageList
                    inputBar
                }
            }
            .navigationTitle("会话")
            .toolbar {
                if !conversation.messages.isEmpty {
                    Button("清空") { conversation.clear() }
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
            Text("请先在「设置 → 模型」中添加 API 配置")
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
                    ForEach(conversation.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if conversation.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding(.trailing, 16)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: conversation.messages.count) { _ in
                if let last = conversation.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("输入消息…", text: $inputText)
                .textFieldStyle(.roundedBorder)

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(inputText.isEmpty ? Color.gray : Color.blue)
                    .clipShape(Circle())
            }
            .disabled(inputText.isEmpty || conversation.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private func send() {
        guard let cfg = modelStore.defaultConfig, !inputText.isEmpty else { return }
        let text = inputText
        inputText = ""
        conversation.send(text, using: cfg)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 50) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.blue : (message.isError ? Color.red.opacity(0.15) : Color(.secondarySystemBackground)))
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(16)
            }
            if !isUser { Spacer(minLength: 50) }
        }
    }
}
