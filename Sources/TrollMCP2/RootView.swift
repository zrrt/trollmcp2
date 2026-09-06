import SwiftUI
import UIKit

final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var drawerOpen = false
    @Published var settingsPresented = false
}

struct RootView: View {
    @ObservedObject private var ui = AppUIState.shared
    @ObservedObject private var lang = LanguageManager.shared   // v2.9.76：语言切换全局刷新
    // v2.9.78：首次启动引导
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "trollmcp2.has_seen_onboarding_v1")

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
        // v2.9.39：内置浏览器悬浮窗（所有界面之上，可缩小到右侧边缘，AI 操作自动浮现）
        // 注意：trailing-closure 版 overlay 仅 iOS15+，项目部署目标 iOS14，用 view 参数版
        .overlay(FloatingBrowserOverlay())
        // v2.9.76：设置改全屏（去掉 sheet 半屏 + 顶部 grabber），子页面头部对齐
        .fullScreenCover(isPresented: Binding(
            get: { ui.settingsPresented },
            set: { ui.settingsPresented = $0 }
        )) {
            SettingsView()
        }
        // v2.9.78：首次启动引导
        .fullScreenCover(isPresented: $showOnboarding, onDismiss: {
            UserDefaults.standard.set(true, forKey: "trollmcp2.has_seen_onboarding_v1")
        }) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: "trollmcp2.has_seen_onboarding_v1")
                showOnboarding = false
            }
        }
        // v2.9.76：语言切换后全局重建视图
        .id(lang.language.rawValue)
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
            NavigationView { DeviceDetectionView(showsDismissButton: true) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(LinearGradient(colors: [.blue, .tmCyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .cornerRadius(9)
            Text(L10n.t("drawer_title"))
                .font(.title3)
                .fontWeight(.bold)
            Spacer()
            Button(action: { withAnimation { ui.drawerOpen = false } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeArea + 8)
        .padding(.bottom, 12)
    }

    /// v2.9.12：状态栏安全区高度（抽屉 ignoredSafeArea 后需手动避让系统时间）
    private var topSafeArea: CGFloat {
        UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
            TextField(L10n.t("drawer_search"), text: $searchText)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(searchText.isEmpty ? 0 : 0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var countLabel: some View {
        HStack {
            Text(L10n.t("drawer_count").replacingOccurrences(of: "{n}", with: "\(store.conversations.count)"))
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
        // v2.9.10：选中行加渐变圆角卡片
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filtered) { conv in
                    Button(action: {
                        store.select(conv.id)
                        withAnimation { ui.drawerOpen = false }
                    }) {
                        conversationRow(conv)
                            .background(
                                Group {
                                    if store.selectedId == conv.id {
                                        LinearGradient(colors: [Color.blue.opacity(0.16), Color.blue.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                                    } else {
                                        Color.clear
                                    }
                                }
                            )
                            .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        // iOS14 兼容：不用 Button(role:)
                        Button(action: { deleteSingle(conv.id) }) {
                            Label(L10n.t("drawer_delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func deleteSingle(_ id: UUID) {
        guard let idx = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.delete(at: IndexSet(integer: idx))
    }

    private func conversationRow(_ conv: ChatConversation) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(store.selectedId == conv.id ? Color.blue : Color(.secondarySystemBackground))
                    .frame(width: 34, height: 34)
                Image(systemName: store.selectedId == conv.id ? "bubble.left.fill" : "message.fill")
                    .font(.system(size: 15))
                    .foregroundColor(store.selectedId == conv.id ? .white : .blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title)
                    .font(.body)
                    .fontWeight(store.selectedId == conv.id ? .semibold : .regular)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(Self.formatter.string(from: conv.updatedAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
        if let ready = deviceReady { return ready ? L10n.t("drawer_ready") : L10n.t("drawer_env_limited") }
        return L10n.t("drawer_probe")
    }

    private func refreshReadiness() {
        // 轻量读取缓存报告，避免每次打开抽屉都全量扫描
        deviceReady = DeviceProbe.shared.lastReport?.ready
    }

    private var bottomWorkbench: some View {
        // v2.9.10：圆角卡片式底部工具栏（环境入口 + 设置齿轮）
        // v2.9.76：就绪图标美化——渐变圆环 + 脉冲点 + 波浪扫描
        HStack(spacing: 10) {
            Button(action: { showDevice = true }) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill((deviceReady == true ? Color.green : Color.orange).opacity(0.14))
                            .frame(width: 32, height: 32)
                        Circle()
                            .stroke(
                                (deviceReady == true ? Color.green : Color.orange).opacity(0.35),
                                lineWidth: 2
                            )
                            .frame(width: 32, height: 32)
                        Image(systemName: deviceReady == true ? "waveform.path.ecg" : "exclamationmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(deviceReady == true ? .green : .orange)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(readinessText)
                            .font(.footnote)
                            .fontWeight(.medium)
                            .foregroundColor(deviceReady == true ? .green : .orange)
                        Text(deviceReady == true ? "TrollStore" : "检测环境")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 38, height: 38)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(11)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
