import SwiftUI

struct InjectionView: View {
    @State private var apps: [AppCatalog.AppEntry] = []
    @State private var searchText = ""
    @State private var selectedApp: AppCatalog.AppEntry?
    @State private var inspectResult: [String: Any]?

    private var filtered: [AppCatalog.AppEntry] {
        if searchText.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleId.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationView {
            Group {
                if apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "syringe")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("点击右上角刷新")
                            .foregroundColor(.secondary)
                    }
                } else {
                    appList
                }
            }
            .navigationTitle("注入管理 (\(apps.count))")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                }
            }
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app, inspectResult: $inspectResult)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: refresh)   // v2.9.18：进入自动加载应用列表
    }

    private var appList: some View {
        List {
            if !searchText.isEmpty {
                Section {
                    EmptyView()
                }
            }
            ForEach(filtered) { app in
                Button(action: { selectedApp = app; inspectApp(app) }) {
                    HStack(spacing: 12) {
                        // v2.9.18：真实 app 图标（加载失败时显示首字母占位）
                        AppIconView(bundleId: app.bundleId, path: app.path)
                            .frame(width: 34, height: 34)
                            .cornerRadius(8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.body)
                                .foregroundColor(.primary)
                            Text(app.bundleId)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .listStyle(.insetGrouped)
    }


    private func refresh() {
        apps = AppCatalog.list()
        AuditLog.shared.log("injection.refresh", detail: "\(apps.count) apps")
    }

    private func inspectApp(_ app: AppCatalog.AppEntry) {
        inspectResult = InjectionManager.shared.inspect(app.bundleId)
    }
}

struct AppDetailView: View {
    let app: AppCatalog.AppEntry
    @Binding var inspectResult: [String: Any]?
    @Environment(\.presentationMode) var presentationMode

    /// v2.9.21：手动注入操作反馈
    @State private var actionMessage: String?
    @State private var busy = false

    private struct DictEntry: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    private var entries: [DictEntry] {
        (inspectResult ?? [:]).sorted { $0.key < $1.key }
            .map { DictEntry(key: $0.key, value: "\($0.value)") }
    }

    private var injected: Bool {
        (inspectResult?["injected"] as? Bool) ?? false
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "应用信息")) {
                    LabeledRow(label: "名称", value: app.name)
                    LabeledRow(label: "Bundle ID", value: app.bundleId)
                    LabeledRow(label: "路径", value: app.path)
                    if let container = app.containerPath {
                        LabeledRow(label: "容器", value: container)
                    }
                }
                // v2.9.21：手动注入 / 移除操作区
                Section(header: SettingSectionHeader(title: "注入操作")) {
                    HStack(spacing: 8) {
                        Image(systemName: injected ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 17))
                            .foregroundColor(injected ? .green : .secondary)
                        Text(injected ? "已注入" : "未注入")
                            .font(.body)
                        Spacer()
                    }
                    if let msg = actionMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(msg.hasPrefix("✅") ? .green : .orange)
                    }
                    Button(action: { doInject() }) {
                        HStack(spacing: 8) {
                            if busy { ProgressView() }
                            Image(systemName: "syringe")
                            Text("注入 TrollMCPAgent")
                        }
                    }
                    .disabled(busy || injected)
                    Button(action: { doRemove() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("移除注入（还原）")
                        }
                    }
                    .disabled(busy || !injected)
                }
                Section(header: SettingSectionHeader(title: "注入工具链")) {
                    ForEach(InjectionManager.shared.availableBinaries(), id: \.self) { bin in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.green)
                                    .frame(width: 34, height: 34)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            Text(bin)
                                .font(.body)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
                if !entries.isEmpty {
                    Section(header: SettingSectionHeader(title: "检查结果")) {
                        ForEach(entries) { e in
                            LabeledRow(label: e.key, value: e.value)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(app.name)
            .toolbar { Button("关闭") { presentationMode.wrappedValue.dismiss() } }
        }
    }

    /// v2.9.21：手动注入
    private func doInject() {
        busy = true
        actionMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [String: Any]
            do {
                result = try InjectionManager.shared.enable(bundleId: app.bundleId)
            } catch {
                let msg = (error as? MCPError)?.description ?? error.localizedDescription
                DispatchQueue.main.async {
                    actionMessage = "❌ 注入失败：\(msg)"
                    busy = false
                }
                return
            }
            DispatchQueue.main.async {
                let ok = (result["injected"] as? Bool) ?? false
                actionMessage = ok ? "✅ 注入成功" : "⚠️ 注入未确认（见检查结果）"
                inspectResult = InjectionManager.shared.inspect(app.bundleId)
                busy = false
            }
        }
    }

    /// v2.9.21：手动移除注入
    private func doRemove() {
        busy = true
        actionMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [String: Any]
            do {
                result = try InjectionManager.shared.remove(bundleId: app.bundleId)
            } catch {
                let msg = (error as? MCPError)?.description ?? error.localizedDescription
                DispatchQueue.main.async {
                    actionMessage = "❌ 移除失败：\(msg)"
                    busy = false
                }
                return
            }
            DispatchQueue.main.async {
                let ok = ((result["injected"] as? Bool) ?? true) == false
                actionMessage = ok ? "✅ 已还原" : "⚠️ 还原未确认"
                inspectResult = InjectionManager.shared.inspect(app.bundleId)
                busy = false
            }
        }
    }
}
