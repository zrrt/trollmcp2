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
    @State private var showDevice = false
    @State private var deviceReady: Bool?

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
        .onAppear(perform: refreshReadiness)
        .sheet(isPresented: $showDevice) {
            NavigationView { DeviceDetectionView() }
        }
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
        // 用 ScrollView + LazyVStack 替代 List，去掉行间分隔线（v2.9.9）
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { conv in
                    Button(action: {
                        store.select(conv.id)
                        withAnimation { ui.drawerOpen = false }
                    }) {
                        conversationRow(conv)
                            .background(
                                store.selectedId == conv.id ? Color.blue.opacity(0.08) : Color.clear
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        // iOS14 兼容：不用 Button(role:)
                        Button(action: { deleteSingle(conv.id) }) {
                            Label("删除对话", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func deleteSingle(_ id: UUID) {
        guard let idx = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.delete(at: IndexSet(integer: idx))
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
        let idxSet = IndexSet(store.conversations.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil })
        store.delete(at: idxSet)
    }

    private var deviceReadinessBar: some View {
        // 已并入 bottomWorkbench 精简入口（v2.9.9），此实现保留备用
        EmptyView()
    }

    private var readinessText: String {
        if let ready = deviceReady { return ready ? "就绪 · 可注入" : "环境受限 · 点按查看" }
        return "点按检测本机"
    }

    private func refreshReadiness() {
        // 轻量读取缓存报告，避免每次打开抽屉都全量扫描
        deviceReady = DeviceProbe.shared.lastReport?.ready
    }

    private var bottomWorkbench: some View {
        // 精简版：去掉大图标与"调试工作台"文字，仅保留环境入口 + 设置（v2.9.9）
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button(action: { showDevice = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path.badge.checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(deviceReady == true ? .green : .orange)
                            .frame(width: 28, height: 28)
                            .background((deviceReady == true ? Color.green : Color.orange).opacity(0.12))
                            .cornerRadius(7)
                        Text(readinessText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                Spacer()
                Button(action: {
                    withAnimation { ui.drawerOpen = false }
                    ui.settingsPresented = true
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
