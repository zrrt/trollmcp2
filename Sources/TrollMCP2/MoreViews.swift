import SwiftUI

struct AuditLogView: View {
    @ObservedObject private var log = AuditLog.shared

    var body: some View {
        NavigationView {
            List {
                if log.entries.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text("暂无审计日志")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 40)
                            Spacer()
                        }
                    }
                } else {
                    ForEach(log.entries) { entry in
                        Section(header: SettingSectionHeader(title: timeString(entry.timestamp))) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.category)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(levelColor(entry.level))
                                    Spacer()
                                    Text(entry.level.rawValue.uppercased())
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(levelColor(entry.level))
                                }
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("审计日志")
            .toolbar {
                Button("清空") { log.clear() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func levelColor(_ level: AuditLog.Entry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

struct BuildView: View {
    @State private var token = ""

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "编译模式")) {
                    SettingRowButton(
                        title: "生成编译令牌",
                        subtitle: "用于验证本地编译请求",
                        icon: "key.fill",
                        color: .orange
                    ) {
                        if let result = try? ToolRegistry.shared.dispatch(name: "build.runner.token", params: ["action": "generate"]),
                           let t = result["token"] as? String {
                            token = t
                        }
                    }
                    if !token.isEmpty {
                        Section {
                            Text(token)
                                .font(.system(.body, design: .monospaced))
                                .padding(.vertical, 4)
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "项目模板")) {
                    SettingRowButton(
                        title: "生成 Tweak 项目模板",
                        subtitle: "在工作区创建 MyTweak 模板",
                        icon: "doc.badge.plus",
                        color: .blue
                    ) {
                        _ = try? ToolRegistry.shared.dispatch(name: "project.generate_tweak", params: ["name": "MyTweak"])
                    }
                }

                Section(header: SettingSectionHeader(title: "说明")) {
                    Text("编译模式允许在 iPhone 上编译 dylib。需要已注入 TMBuildAgent.dylib 到 TrollMCP。编译令牌用于验证编译请求。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("编译")
        }
        .navigationViewStyle(.stack)
    }
}

struct SystemCapabilitiesView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "系统能力")) {
                    capRow("通讯录搜索", "contacts.search", "person.crop.circle", .blue)
                    capRow("日历事件", "calendar.list", "calendar", .red)
                    capRow("提醒事项", "reminder.create", "checkmark.square", .green)
                    capRow("定位", "location.get", "location", .tmIndigo)
                    capRow("本地通知", "notification.send", "bell", .orange)
                    capRow("扫码识别", "scan.qr", "qrcode.viewfinder", .purple)
                    capRow("进程枚举", "process.list", "list.bullet", .gray)
                }

                Section(header: SettingSectionHeader(title: "说明")) {
                    Text("首次调用系统能力时会请求对应权限。未授权的工具调用将返回错误信息。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("系统能力")
        }
        .navigationViewStyle(.stack)
    }

    private func capRow(_ name: String, _ tool: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color)
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                Text(tool)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 工具权限策略

struct ToolPermissionPoliciesView: View {
    @ObservedObject private var registry = ToolRegistry.shared
    @State private var searchText = ""
    // v2.9.23：并入原"本机工具审计"的真实实现清单（标记哪些工具有真实实现 vs 占位）
    @State private var showOnlyReal = false

    private let realTools: Set<String> = [
        "ping",
        "device.info",
        "device.probe",
        "artifact.read_text",
        "artifact.write_text",
        "artifact.list",
        "workspace.info",
        "assistant.memory_set",
        "assistant.memory_list",
        "assistant.memory_delete",
        "apps.cache_inspect",
        "apps.cache_clear",
        "apps.open",
        "apps.open_and_input",
        "wechat.prepare_message",
        "container.write_text",
        "container.delete",
        "contacts.search",
        "calendar.list",
        "reminder.create",
        "location.get",
        "notification.send",
        "scan.qr",
        "process.list",
        "build.runner.token",
        "project.generate_tweak",
        "model.config",
        "model.authentication",
        "model.selectedProfileID",
        "workspace.outputBookmark",
        "workspace.outputName",
        // v2.9.21：注入执行工具真实可用
        "injection.enable",
        "injection.disable",
        "injection.status",
        "injection.inspect",
        "injection.list",
        "injection.remove",
        // v2.9.17：技能真实可用
        "skills.list",
        "skills.read",
        "skills.set_enabled",
        "tool_search"
    ]

    private var filtered: [ToolDefinition] {
        var defs = registry.definitions
        if showOnlyReal {
            defs = defs.filter { realTools.contains($0.name) }
        }
        if searchText.isEmpty { return defs }
        return defs.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.summary.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "策略")) {
                    HStack {
                        Text("已启用")
                        Spacer()
                        Text("\(registry.enabledDefinitions.count)/\(registry.definitions.count)")
                            .foregroundColor(.secondary)
                    }
                    // v2.9.31：工具按需加载——初始请求只带常驻核心（标★），其余靠搜索加载；
                    // v2.9.32：去掉授权弹窗，AI 搜索到工具即自动放行本会话。
                    Text("初始请求只加载常驻核心工具（标 ★，无需搜索），其余工具由 AI 用「工具搜索」按需加载，搜索命中即自动放行本会话、无弹窗。此页开关控制该工具是否默认可用：关闭的工具 AI 仍可先搜索再调用。全量勾选不影响请求速度。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SettingRowButton(
                        title: "全部启用",
                        subtitle: "恢复所有工具调用权限",
                        icon: "checkmark.circle",
                        color: .green
                    ) {
                        for d in registry.definitions { registry.setEnabled(name: d.name, enabled: true) }
                    }
                    SettingRowButton(
                        title: "全部禁用",
                        subtitle: "仅保留浏览",
                        icon: "xmark.circle",
                        color: .red
                    ) {
                        for d in registry.definitions { registry.setEnabled(name: d.name, enabled: false) }
                    }
                }

                // v2.9.23：并入原"本机工具审计"的过滤
                Section(header: SettingSectionHeader(title: "过滤")) {
                    Toggle("仅显示真实实现", isOn: $showOnlyReal)
                    Text("「真实」= 有实际执行逻辑；「占位」= 仅注册了接口、未接入真实功能。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: SettingSectionHeader(title: "工具列表")) {
                    ForEach(filtered, id: \.name) { def in
                        let isOn = registry.isEnabled(name: def.name)
                        let isCore = registry.isCore(def.name)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(isCore ? "★ " : "")
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.blue)
                                    + Text(def.name)
                                        .font(.system(.body, design: .monospaced))
                                    Text(realTools.contains(def.name) ? "真实" : "占位")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background((realTools.contains(def.name) ? Color.green : Color.orange).opacity(0.15))
                                        .foregroundColor(realTools.contains(def.name) ? .green : .orange)
                                        .cornerRadius(4)
                                }
                                Text(def.summary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            // v2.9.26：自定义 iOS 风格开关（绕开 List+Toggle 兼容问题，整行可点切换）
                            ZStack(alignment: isOn ? .trailing : .leading) {
                                Capsule()
                                    .fill(isOn ? Color.green : Color(.systemGray4))
                                    .frame(width: 46, height: 28)
                                Circle()
                                    .fill(Color.white)
                                    .shadow(radius: 1)
                                    .frame(width: 24, height: 24)
                                    .padding(2)
                            }
                            .animation(.easeInOut(duration: 0.15))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            registry.setEnabled(name: def.name, enabled: !registry.isEnabled(name: def.name))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("工具权限策略")
            .toolbar {
                HStack {
                    if !searchText.isEmpty {
                        Button("清除") { searchText = "" }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 数据管理

struct DataManagementView: View {
    @State private var files: [WorkspaceItem] = []
    @State private var showingImporter = false

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "工作区")) {
                    LabeledRow(label: "路径", value: Workspace.root.path)
                    SettingRowButton(
                        title: "在会话工具中打开",
                        subtitle: "使用 artifact.* 读写",
                        icon: "folder",
                        color: .blue
                    ) {
                        AuditLog.shared.log("data.open_workspace", detail: Workspace.root.path)
                    }
                    SettingRowButton(
                        title: "清空工作区",
                        subtitle: "删除 Documents/Workspace 下所有文件",
                        icon: "trash",
                        color: .red
                    ) {
                        try? FileManager.default.removeItem(at: Workspace.root)
                        Workspace.ensure()
                        refresh()
                    }
                }

                Section(header: SettingSectionHeader(title: "文件")) {
                    ForEach(files) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.body)
                                Text(item.size)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            try? FileManager.default.removeItem(at: files[i].url)
                        }
                        refresh()
                    }
                }

                Section(header: SettingSectionHeader(title: "导入")) {
                    SettingRowButton(
                        title: "导入文件到工作区",
                        subtitle: "选择外部文件复制到工作区",
                        icon: "doc.badge.plus",
                        color: .green
                    ) {
                        showingImporter = true
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("数据管理")
            .toolbar {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
            }
            .sheet(isPresented: $showingImporter) {
                DocumentImporter { url in
                    _ = try? FileManager.default.copyItem(at: url, to: Workspace.root.appendingPathComponent(url.lastPathComponent))
                    refresh()
                }
            }
            .onAppear(perform: refresh)
        }
        .navigationViewStyle(.stack)
    }

    private func refresh() {
        Workspace.ensure()
        var items: [WorkspaceItem] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: Workspace.root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if !isDir.boolValue {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    items.append(WorkspaceItem(name: url.lastPathComponent, size: byteString(size), url: url))
                }
            }
        }
        files = items.sorted { $0.name < $1.name }
    }

    private func byteString(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / (1024 * 1024))
    }
}

struct WorkspaceItem: Identifiable {
    var id = UUID()
    let name: String
    let size: String
    let url: URL
}

// MARK: - 文档导入器

struct DocumentImporter: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .open)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.first.map(onPick)
        }
    }
}

// MARK: - 开发者指令（v2.9.19：可自建/编辑/设默认）

struct DeveloperInstructionsView: View {
    @State private var items: [DeveloperInstructionStore.Item] = []
    @State private var editing: DevInstrEditorPayload?
    @State private var creating = false
    // v2.9.24：一键复制提示
    @State private var copiedName: String?

    var body: some View {
        NavigationView {
            List {
                if items.isEmpty {
                    Section {
                        Text("还没有开发者指令，点右上角 + 新建。")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .font(.body)
                                    .foregroundColor(item.enabled ? .primary : .secondary)
                                if item.isDefault {
                                    Text("默认")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundColor(.blue)
                                        .cornerRadius(6)
                                }
                                Spacer()
                                // v2.9.24：一键复制按钮（无需长按）
                                Button(action: { copyItem(item) }) {
                                    Image(systemName: copiedName == item.name ? "checkmark" : "doc.on.doc")
                                        .font(.subheadline)
                                        .foregroundColor(copiedName == item.name ? .green : .blue)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            Text(preview(item.content))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editing = DevInstrEditorPayload(name: item.name, content: item.content)
                        }
                        .contextMenu {
                            if !item.isDefault {
                                Button(action: { makeDefault(item) }) {
                                    Label("设为默认（注入 AI）", systemImage: "checkmark.seal.fill")
                                }
                            }
                            Button(action: { copyItem(item) }) {
                                Label("复制内容", systemImage: "doc.on.doc")
                            }
                            Button(action: {
                                editing = DevInstrEditorPayload(name: item.name, content: item.content)
                            }) {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button(action: { remove(item) }) {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    Section {
                        Toggle("AI 请求注入默认指令", isOn: Binding(
                            get: { DeveloperInstructionStore.shared.defaultInjectionContent() != nil },
                            set: { _ in }
                        ))
                        .disabled(true)
                    } footer: {
                        Text("默认指令（标「默认」）会在每次 AI 请求时作为 system 消息注入，AI 将遵循其中的约定。长按指令可设默认/编辑/删除。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("开发者指令")
            .onAppear(perform: reload)
            .toolbar {
                Button(action: { creating = true }) { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { payload in
                DevInstructionEditorView(name: payload.name, initialContent: payload.content, mode: .edit)
            }
            .sheet(isPresented: $creating) {
                DevInstructionEditorView(name: "", initialContent: "", mode: .create)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func preview(_ c: String) -> String {
        let lines = c.split(separator: "\n").map(String.init)
        // 取第一个非空、非标题行作摘要
        for ln in lines {
            let t = ln.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("#") { return String(t.prefix(60)) }
        }
        return c.isEmpty ? "（空指令）" : String(c.prefix(60))
    }

    private func reload() {
        items = DeveloperInstructionStore.shared.list()
    }

    private func makeDefault(_ item: DeveloperInstructionStore.Item) {
        DeveloperInstructionStore.shared.setDefault(name: item.name)
        reload()
    }

    /// v2.9.20：复制指令内容到剪贴板
    private func copyItem(_ item: DeveloperInstructionStore.Item) {
        UIPasteboard.general.string = item.content
        // v2.9.24：复制成功反馈（图标变绿 checkmark，1.5s 后恢复）
        withAnimation { copiedName = item.name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedName == item.name {
                withAnimation { copiedName = nil }
            }
        }
    }

    private func remove(_ item: DeveloperInstructionStore.Item) {
        DeveloperInstructionStore.shared.delete(name: item.name)
        reload()
    }
}

struct DevInstrEditorPayload: Identifiable {
    var id: String { name }
    let name: String
    let content: String
}

struct DevInstructionEditorView: View {
    enum Mode { case create, edit }
    let name: String
    let initialContent: String
    let mode: Mode

    @State private var title = ""
    @State private var content = ""
    @State private var keyboardHeight: CGFloat = 0
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            // v2.9.22：Form 里 TextEditor 滚动冲突/键盘遮挡导致"难往下滑"，
            // 改为 ScrollView + 大高度 TextEditor + 键盘高度避让
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: "指令名称")
                        TextField("如：我的工程规范", text: $title)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: "指令内容（Markdown）")
                        TextEditor(text: $content)
                            .frame(minHeight: 520)
                            .font(.system(.body, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color(.separator), lineWidth: 0.5)
                            )
                            .cornerRadius(10)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: "说明")
                        Text("默认指令会注入 AI 请求。可写：工程约定、代码风格、工具使用偏好、回复格式要求等。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    // v2.9.22：iOS14 兼容的收起键盘按钮
                    Button(action: hideKeyboard) {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard.chevron.compact.down")
                            Text("收起键盘")
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
                .padding()
                // 键盘弹出时底部留白，确保能滚到末尾
                .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 16 : 24)
            }
            .navigationTitle(mode == .create ? "新建指令" : "编辑指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                // v2.9.24：编辑时一键复制当前内容
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: copyContent) {
                            Image(systemName: "doc.on.doc")
                        }
                        Button("保存") { save() }
                    }
                }
            }
            .onAppear {
                if mode == .edit && title.isEmpty {
                    title = name
                    content = initialContent
                }
                observeKeyboard()
            }
        }
        .navigationViewStyle(.stack)
    }

    /// v2.9.22：监听键盘高度（iOS14 兼容，不用 scrollDismissesKeyboard）
    private func observeKeyboard() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
            if let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.height {
                keyboardHeight = h
            }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            keyboardHeight = 0
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if mode == .create {
            DeveloperInstructionStore.shared.create(name: trimmed, content: content)
        } else {
            DeveloperInstructionStore.shared.update(name: trimmed, content: content)
        }
        presentationMode.wrappedValue.dismiss()
    }

    /// v2.9.24：编辑器一键复制当前内容
    private func copyContent() {
        UIPasteboard.general.string = content
    }
}

// MARK: - 本机知识库

struct KnowledgeBaseView: View {
    @State private var files: [WorkspaceItem] = []
    @State private var showingImporter = false

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "来源")) {
                    SettingRowButton(
                        title: "导入文件",
                        subtitle: "Markdown / TXT / JSON / PDF",
                        icon: "doc.badge.plus",
                        color: .blue
                    ) {
                        showingImporter = true
                    }
                    SettingRowButton(
                        title: "从工作区导入",
                        subtitle: "使用 workspace 目录内的文件",
                        icon: "folder.badge.plus",
                        color: .green
                    ) {
                        importFromWorkspace()
                    }
                }

                Section(header: SettingSectionHeader(title: "已导入")) {
                    if files.isEmpty {
                        Text("暂无知识库文件")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(files) { item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text(item.size)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                try? FileManager.default.removeItem(at: files[i].url)
                            }
                            refresh()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("本机知识库")
            .toolbar {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
            }
            .sheet(isPresented: $showingImporter) {
                DocumentImporter { url in
                    let dest = knowledgeBaseDir.appendingPathComponent(url.lastPathComponent)
                    _ = try? FileManager.default.copyItem(at: url, to: dest)
                    refresh()
                }
            }
            .onAppear(perform: refresh)
        }
        .navigationViewStyle(.stack)
    }

    private var knowledgeBaseDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("KnowledgeBase")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func refresh() {
        var items: [WorkspaceItem] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: knowledgeBaseDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                items.append(WorkspaceItem(name: url.lastPathComponent, size: byteString(size), url: url))
            }
        }
        files = items.sorted { $0.name < $1.name }
    }

    private func importFromWorkspace() {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: Workspace.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let dest = knowledgeBaseDir.appendingPathComponent(url.lastPathComponent)
                _ = try? fm.copyItem(at: url, to: dest)
            }
        }
        refresh()
    }

    private func byteString(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / (1024 * 1024))
    }
}

// MARK: - Webhooks 设置

struct WebhooksView: View {
    @State private var url = ""
    @State private var secret = ""
    @State private var events = ""
    @State private var status = ""

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "端点")) {
                    editorRow("URL", text: $url, placeholder: "https://example.com/webhook")
                    editorRow("Secret", text: $secret, placeholder: "可选签名密钥")
                    editorRow("事件", text: $events, placeholder: "audit,tool_call")
                }

                Section(header: SettingSectionHeader(title: "操作")) {
                    Button(action: save) {
                        Text("保存配置")
                            .foregroundColor(.blue)
                    }
                    Button(action: test) {
                        HStack {
                            Text("发送测试事件")
                                .foregroundColor(.blue)
                            Spacer()
                        }
                    }
                }

                if !status.isEmpty {
                    Section(header: SettingSectionHeader(title: "状态")) {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Webhooks")
        }
        .navigationViewStyle(.stack)
    }

    private func editorRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        UserDefaults.standard.set(["url": url, "secret": secret, "events": events], forKey: "trollmcp2.webhook")
        status = "已保存"
    }

    private func test() {
        guard let target = URL(string: url), !url.isEmpty else {
            status = "URL 无效"
            return
        }
        var req = URLRequest(url: target, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["event": "test", "timestamp": ISO8601DateFormatter().string(from: Date()), "app": "TrollMCP2"] as [String: Any]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    status = "失败: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse {
                    status = "HTTP \(http.statusCode)"
                } else {
                    status = "已发送"
                }
            }
        }.resume()
    }
}

// MARK: - Agents 与 Skills

struct AgentsAndSkillsView: View {
    @State private var skills: [SkillItem] = []
    @State private var agents: [AgentItem] = []
    @State private var showSkillEditor = false
    @State private var showAgentEditor = false

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "Skills")) {
                    if skills.isEmpty {
                        Text("暂无技能，点右上角 + 新建")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(skills) { s in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name)
                                        .font(.body)
                                        .foregroundColor(SkillStore.shared.isEnabled(s.name) ? .primary : .secondary)
                                    Text(s.summary.isEmpty ? s.instruction : s.summary)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { SkillStore.shared.isEnabled(s.name) },
                                    set: { SkillStore.shared.setEnabled(s.name, $0); reload() }
                                ))
                                .labelsHidden()
                                .frame(width: 46)
                                Button(action: {
                                    SkillStore.shared.delete(named: s.name)
                                    reload()
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "Agents")) {
                    if agents.isEmpty {
                        Text("暂无自定义 Agent")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(agents) { a in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name)
                                        .font(.body)
                                    Text(a.systemPrompt)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "说明")) {
                    Text("技能是预置的工作流指令：AI 可用 skills.list 发现、skills.read 读取并执行。可在本页启用/停用/删除，或点 + 新建。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Agents 通过 agents.json 配置，放入 KnowledgeBase 目录即可加载。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Agents 与 Skills")
            .onAppear {
                SkillStore.shared.seedIfEmpty()
                reload()
            }
            .toolbar {
                Button(action: { showSkillEditor = true }) { Image(systemName: "plus.square.on.square") }
                Button(action: { showAgentEditor = true }) { Image(systemName: "person.badge.plus") }
            }
            .sheet(isPresented: $showSkillEditor) { SkillEditorView() }
            .sheet(isPresented: $showAgentEditor) { AgentEditorView() }
        }
        .navigationViewStyle(.stack)
    }

    private func reload() {
        skills = SkillStore.shared.all
        let kb = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("KnowledgeBase")
        if let data = try? Data(contentsOf: kb.appendingPathComponent("agents.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            agents = json.map { AgentItem(name: $0["name"] ?? "", systemPrompt: $0["systemPrompt"] ?? "") }
        }
    }
}

struct AgentItem: Identifiable {
    var id = UUID()
    let name: String
    let systemPrompt: String
}
