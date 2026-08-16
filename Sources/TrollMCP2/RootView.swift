import SwiftUI

final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var drawerOpen = false
    @Published var settingsPresented = false
}

struct RootView: View {
    @ObservedObject private var ui = AppUIState.shared

    var body: some View {
        ZStack {
            ChatView()
                .disabled(ui.drawerOpen)

            if ui.drawerOpen {
                Color.black
                    .opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { ui.drawerOpen = false } }
            }

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ConversationDrawerView()
                        .frame(width: drawerWidth(for: geo))
                        .offset(x: ui.drawerOpen ? 0 : -drawerWidth(for: geo))
                        .animation(.easeInOut)
                        .edgesIgnoringSafeArea(.vertical)
                        .allowsHitTesting(ui.drawerOpen)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { ui.settingsPresented },
            set: { ui.settingsPresented = $0 }
        )) {
            SettingsView()
        }
    }

    private func drawerWidth(for geo: GeometryProxy) -> CGFloat {
        min(geo.size.width * 0.78, 320)
    }
}

struct ConversationDrawerView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var ui = AppUIState.shared
    @State private var searchText = ""

    private var filtered: [ChatConversation] {
        if searchText.isEmpty { return store.conversations }
        return store.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            countLabel
            conversationList
            bottomWorkbench
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        HStack {
            Text("对话")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button(action: { withAnimation { ui.drawerOpen = false } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 30, height: 30)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索对话内容...", text: $searchText)
                .font(.body)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal, 16)
    }

    private var countLabel: some View {
        HStack {
            Text("\(store.conversations.count) 个本机对话")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var conversationList: some View {
        List {
            ForEach(filtered) { conv in
                Button(action: {
                    store.select(conv.id)
                    withAnimation { ui.drawerOpen = false }
                }) {
                    conversationRow(conv)
                }
                .listRowBackground(
                    store.selectedId == conv.id ? Color.blue.opacity(0.08) : Color.clear
                )
            }
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
    }

    private func conversationRow(_ conv: ChatConversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "message")
                .font(.system(size: 20))
                .foregroundColor(.blue)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(conv.title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(Self.formatter.string(from: conv.updatedAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { filtered[$0].id }
        if let idxSet = IndexSet(store.conversations.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil }) {
            store.delete(at: idxSet)
        }
    }

    private var bottomWorkbench: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                IconBadge(icon: "cpu", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TrollMCP")
                        .font(.body)
                        .fontWeight(.medium)
                    Text("本机调试工作台")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: {
                    withAnimation { ui.drawerOpen = false }
                    ui.settingsPresented = true
                }) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
