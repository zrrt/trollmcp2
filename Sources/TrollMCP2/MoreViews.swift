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

    private var filtered: [ToolDefinition] {
        let defs = registry.definitions
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

                Section(header: SettingSectionHeader(title: "工具列表")) {
                    ForEach(filtered) { def in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(def.name)
                                    .font(.body)
                                Text(def.summary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { registry.isEnabled(name: def.name) },
                                set: { registry.setEnabled(name: def.name, enabled: $0) }
                            ))
                            .labelsHidden()
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

// MARK: - 开发者指令

struct DeveloperInstructionsView: View {
    @State private var content = "加载中..."

    var body: some View {
        NavigationView {
            ScrollView {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("开发者指令")
            .onAppear(perform: load)
            .toolbar {
                Button(action: load) { Image(systemName: "arrow.clockwise") }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func load() {
        let candidates = [
            Bundle.main.url(forResource: "TrollMCPDeveloperInstructions", withExtension: "md"),
            Bundle.main.url(forResource: "TrollMCPDeveloperInstructions", withExtension: "md", subdirectory: "bin"),
            Bundle.main.url(forResource: "TrollMCPDeveloperInstructions", withExtension: "md", subdirectory: "")
        ]
        for url in candidates {
            if let url = url, let text = try? String(contentsOf: url, encoding: .utf8) {
                content = text
                return
            }
        }
        content = "未在 App Bundle 中找到 TrollMCPDeveloperInstructions.md。\n\n请在构建前将原包中的 TrollMCPDeveloperInstructions.md 放入 Resources 目录。"
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

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "Skills")) {
                    if skills.isEmpty {
                        Text("暂无自定义 Skill")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(skills) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name)
                                        .font(.body)
                                    Text(s.instruction)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
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
                    Text("Skills 与 Agents 通过本地 JSON 文件配置。将 skills.json / agents.json 放入 KnowledgeBase 目录即可加载。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Agents 与 Skills")
            .onAppear(perform: load)
        }
        .navigationViewStyle(.stack)
    }

    private func load() {
        let kb = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("KnowledgeBase")
        if let data = try? Data(contentsOf: kb.appendingPathComponent("skills.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            skills = json.map { SkillItem(name: $0["name"] ?? "", instruction: $0["instruction"] ?? "") }
        }
        if let data = try? Data(contentsOf: kb.appendingPathComponent("agents.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            agents = json.map { AgentItem(name: $0["name"] ?? "", systemPrompt: $0["systemPrompt"] ?? "") }
        }
    }
}

struct SkillItem: Identifiable {
    var id = UUID()
    let name: String
    let instruction: String
}

struct AgentItem: Identifiable {
    var id = UUID()
    let name: String
    let systemPrompt: String
}
