import SwiftUI

struct InjectionView: View {
    @State private var apps: [AppCatalog.AppEntry] = []
    @State private var searchText = ""
    @State private var selectedApp: AppCatalog.AppEntry?
    @State private var inspectResult: [String: Any]?
    // v2.9.92：紧急恢复区块
    @State private var showRescue = false
    @State private var rescueBusy = false
    @State private var rescueMessage: String?
    @State private var rescueAlert = false
    @State private var pendingRescue: String?

    private var filtered: [AppCatalog.AppEntry] {
        if searchText.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleId.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部（标题 + 搜索）
            PageHeader(
                icon: "syringe.fill",
                title: L10n.t("page_inject"),
                subtitle: "\(apps.count) 个应用 · 点击查看详情与注入",
                colors: [.tmIndigo, .tmCyan]
            )
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
                TextField("搜索应用或 Bundle ID...", text: $searchText)
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
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            // v2.9.92：🚑 紧急恢复（Residue 式）——注入把 App 搞坏后的第一选择
            rescueSection
                .padding(.bottom, 6)

            Group {
                if apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "syringe")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("点击右上角刷新")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    appList
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                }
            }
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app, inspectResult: $inspectResult)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_inject"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)   // v2.9.18：进入自动加载应用列表
    }

    private var appList: some View {
        List {
            ForEach(filtered) { app in
                Button(action: { selectedApp = app; inspectApp(app) }) {
                    HStack(spacing: 12) {
                        // v2.9.18：真实 app 图标（加载失败时显示首字母占位）
                        AppIconView(bundleId: app.bundleId, path: app.path)
                            .frame(width: 38, height: 38)
                            .cornerRadius(10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.body)
                                .foregroundColor(.primary)
                            Text(app.bundleId)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - v2.9.92 紧急恢复（Residue 式）
    private var rescueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showRescue.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "cross.case.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.orange)
                    Text("🚑 紧急恢复（Residue 式）")
                        .font(.subheadline.bold())
                        .foregroundColor(.orange)
                    Spacer()
                    if rescueBusy {
                        ProgressView()
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showRescue ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                )
            }
            .buttonStyle(PlainButtonStyle())

            if showRescue {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        rescueButton(title: "全机扫描", icon: "magnifyingglass", color: .blue, action: { runRescue("scan") })
                        rescueButton(title: "一键全恢复", icon: "arrow.uturn.backward.circle", color: .orange, action: { confirmRescue("recover_all") })
                        rescueButton(title: "清理残留", icon: "sparkles", color: .red, action: { confirmRescue("cleanup") })
                    }
                    if let msg = rescueMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(msg.hasPrefix("✅") ? .green : (msg.hasPrefix("❌") ? .red : .secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    }
                    Text("App 注入后打不开 → 先「一键全恢复」；仍不行再「清理残留」。不要卸载重装（会丢数据）。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
            }
        }
        .padding(.horizontal, 16)
        .alert(isPresented: $rescueAlert) {
            Alert(title: Text("确认执行"),
                  message: Text(pendingRescue == "recover_all"
                                ? "将扫描并自动恢复所有存在注入痕迹/损坏二进制的 App（还原到注入前状态）。确定继续？"
                                : "将删除注入标记、孤儿备份与 Frameworks 内非系统 dylib。确定继续？"),
                  primaryButton: .destructive(Text("执行")) {
                      if let p = pendingRescue { runRescue(p) }
                  },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    private func rescueButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(title)
                    .font(.caption.bold())
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.10)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(rescueBusy)
    }

    private func confirmRescue(_ kind: String) {
        pendingRescue = kind
        rescueAlert = true
    }

    private func runRescue(_ kind: String) {
        rescueBusy = true
        rescueMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [String: Any]
            do {
                switch kind {
                case "scan": result = try RescueScanTool().invoke([:])
                case "recover_all": result = try RescueRecoverAllTool().invoke([:])
                default: result = try RescueCleanupTool().invoke([:])
                }
            } catch {
                DispatchQueue.main.async {
                    rescueMessage = "❌ 失败：\(error.localizedDescription)"
                    rescueBusy = false
                }
                return
            }
            DispatchQueue.main.async {
                switch kind {
                case "scan":
                    let count = result["count"] as? Int ?? 0
                    rescueMessage = "🔍 扫描完成：发现 \(count) 个需恢复的 App（已注入/损坏/有备份）"
                case "recover_all":
                    let restored = result["restored_count"] as? Int ?? 0
                    let failed = result["failed_count"] as? Int ?? 0
                    rescueMessage = failed == 0 ? "✅ 一键恢复完成：还原 \(restored) 个 App" : "⚠️ 还原 \(restored) 个，\(failed) 个失败：\(result["failed"] ?? "")"
                default:
                    let cleaned = result["cleaned_count"] as? Int ?? 0
                    let errors = result["errors"] as? [String] ?? []
                    rescueMessage = errors.isEmpty ? "✅ 清理完成：\(cleaned) 项残留已清理" : "⚠️ 清理 \(cleaned) 项，\(errors.count) 个错误：\(errors.joined(separator: "; "))"
                }
                AuditLog.shared.log("rescue.ui", detail: "\(kind) \(rescueMessage ?? "")")
                rescueBusy = false
            }
        }
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
                    // v2.9.92：从 .troll-fools.bak 恢复备份（App 打不开时的强恢复）
                    Button(action: { doRestore() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "cross.case.fill")
                            Text("恢复备份（.troll-fools.bak）")
                        }
                    }
                    .disabled(busy)
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

    /// v2.9.92：从 .troll-fools.bak 恢复备份（App 打不开时强恢复）
    private func doRestore() {
        busy = true
        actionMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [String: Any]
            do {
                result = try InjectionRestoreTool().invoke(["bundle_id": app.bundleId])
            } catch {
                let msg = (error as? MCPError)?.description ?? error.localizedDescription
                DispatchQueue.main.async {
                    actionMessage = "❌ 恢复失败：\(msg)"
                    busy = false
                }
                return
            }
            DispatchQueue.main.async {
                let restored = ((result["status"] as? String) == "reverted") || !((result["restored_from_backup"] as? [String]) ?? []).isEmpty
                actionMessage = restored ? "✅ 已从备份恢复" : "⚠️ 未发现可用备份（可能本来就未注入）"
                inspectResult = InjectionManager.shared.inspect(app.bundleId)
                busy = false
            }
        }
    }
}
