import SwiftUI
import Combine

// MARK: - 审批中心（ApprovalSheet / OperationView 共用）

final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    struct Pending: Identifiable, Hashable {
        var id = UUID()
        var toolName: String
        var summary: String
        var params: String
        var submittedAt = Date()
        var decision: Decision = .pending

        enum Decision { case pending, approved, denied }
    }

    @Published var pending: [Pending] = []

    func submit(tool: String, summary: String, params: String) {
        pending.insert(Pending(toolName: tool, summary: summary, params: params), at: 0)
        AuditLog.shared.log("approval", detail: "待审批: \(tool)")
    }

    func approve(_ item: Pending) {
        if let idx = pending.firstIndex(where: { $0.id == item.id }) { pending[idx].decision = .approved }
        AuditLog.shared.log("approval", detail: "已批准: \(item.toolName)")
    }

    func deny(_ item: Pending) {
        if let idx = pending.firstIndex(where: { $0.id == item.id }) { pending[idx].decision = .denied }
        AuditLog.shared.log("approval", detail: "已拒绝: \(item.toolName)", level: .warning)
    }
}

// MARK: - 操作中枢（原版 OperationView）

struct OperationView: View {
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var automations = AutomationStore.shared
    @ObservedObject private var audit = AuditLog.shared

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "待批准操作")) {
                    if approvals.pending.filter({ $0.decision == .pending }).isEmpty {
                        Text("暂无待批准操作")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(approvals.pending.filter { $0.decision == .pending }) { item in
                            NavigationLink(destination: ApprovalSheet(item: item)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.toolName)
                                        .font(.system(.body, design: .monospaced))
                                    Text(item.summary)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "运行中自动化")) {
                    let running = automations.tasks.filter { $0.enabled }
                    if running.isEmpty {
                        Text("暂无启用的自动化任务")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(running) { t in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name)
                                    Text(t.schedule)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("立即运行") {
                                    _ = AutomationStore.shared.run(name: t.name)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "最近活动")) {
                    ForEach(audit.entries.prefix(10)) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.detail)
                                .font(.subheadline)
                            Text("\(e.category) · \(Self.timeFormatter.string(from: e.timestamp))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("操作")
        }
        .navigationViewStyle(.stack)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 审批表单（原版 ApprovalSheet）

struct ApprovalSheet: View {
    @ObservedObject private var center = ApprovalCenter.shared
    let item: ApprovalCenter.Pending

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "工具调用")) {
                    LabeledRow(label: "工具", value: item.toolName)
                    LabeledRow(label: "说明", value: item.summary)
                    LabeledRow(label: "提交时间", value: OperationView.timeFormatter.string(from: item.submittedAt))
                }
                Section(header: SettingSectionHeader(title: "参数")) {
                    Text(item.params)
                        .font(.system(.caption, design: .monospaced))
                }
                Section {
                    Button(action: { center.approve(item) }) {
                        Text("批准执行").foregroundColor(.green)
                    }
                    Button(action: { center.deny(item) }) {
                        Text("拒绝").foregroundColor(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("审批")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 会话完整记录（原版 ConversationTranscriptView）

struct ConversationTranscriptView: View {
    @ObservedObject private var store = ConversationStore.shared

    private var messages: [ChatMessage] {
        guard let idx = store.selectedIndex else { return [] }
        return store.conversations[idx].messages
    }

    var body: some View {
        NavigationView {
            List {
                if messages.isEmpty {
                    Text("暂无历史会话记录")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(messages) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(msg.role == "user" ? "我" : (msg.role == "assistant" ? "助手" : "系统"))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(msg.role == "user" ? .blue : .green)
                                Spacer()
                                Text(Self.tf.string(from: msg.timestamp))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(msg.content)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("会话记录")
            .toolbar {
                if !messages.isEmpty {
                    Button("清空") { store.clearCurrent() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    static let tf: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

// MARK: - 助手角色配置（原版 AssistantProfilesView）

struct AssistantProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var systemPrompt: String
    var modelConfigId: UUID?
    var temperature: Double = 0.7
}

final class AssistantProfileStore: ObservableObject {
    static let shared = AssistantProfileStore()
    @Published var profiles: [AssistantProfile] = []
    private let key = "trollmcp2.assistant_profiles"

    init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([AssistantProfile].self, from: data) {
            profiles = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct AssistantProfilesView: View {
    @ObservedObject private var store = AssistantProfileStore.shared
    @State private var editing: AssistantProfile?

    var body: some View {
        NavigationView {
            List {
                if store.profiles.isEmpty {
                    Text("暂无助手角色，点右上角 + 新建")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.profiles) { p in
                        NavigationLink(destination: AssistantProfileEditor(profile: p)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(p.systemPrompt)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.profiles.remove(atOffsets: offsets)
                        store.save()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("助手角色")
            .toolbar {
                Button(action: {
                    editing = AssistantProfile(name: "新角色", systemPrompt: "你是一个有帮助的助手。")
                }) { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { profile in
                AssistantProfileEditor(profile: profile)
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct AssistantProfileEditor: View {
    @ObservedObject private var store = AssistantProfileStore.shared
    @ObservedObject private var models = ModelStore.shared
    @State var profile: AssistantProfile
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: SettingSectionHeader(title: "基本信息")) {
                    TextField("名称", text: $profile.name)
                }
                Section(header: SettingSectionHeader(title: "系统提示词")) {
                    TextEditor(text: $profile.systemPrompt)
                        .frame(minHeight: 120)
                }
                Section(header: SettingSectionHeader(title: "关联模型")) {
                    Picker("模型配置", selection: $profile.modelConfigId) {
                        Text("默认").tag(UUID?.none)
                        ForEach(models.configs) { c in
                            Text(c.name).tag(UUID?.some(c.id))
                        }
                    }
                }
                Section(header: SettingSectionHeader(title: "参数")) {
                    HStack {
                        Text("温度")
                        Slider(value: $profile.temperature, in: 0...2, step: 0.1)
                        Text(String(format: "%.1f", profile.temperature))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 32)
                    }
                }
                Section {
                    Button("保存") {
                        if let idx = store.profiles.firstIndex(where: { $0.id == profile.id }) {
                            store.profiles[idx] = profile
                        } else {
                            store.profiles.append(profile)
                        }
                        store.save()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle(profile.name.isEmpty ? "新角色" : profile.name)
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 附件面板（原版 AttachmentBottomPanel）

final class AttachmentStore: ObservableObject {
    static let shared = AttachmentStore()
    @Published var items: [String] = []

    func add(_ name: String) {
        items.append(name)
        AuditLog.shared.log("attachment", detail: name)
    }
}

struct AttachmentBottomPanel: View {
    @ObservedObject private var store = AttachmentStore.shared
    @State private var showImporter = false
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "添加附件")) {
                    Button(action: { showImporter = true }) {
                        Label("从文件选择", systemImage: "folder")
                    }
                    Button(action: { store.add("相机照片.jpg") }) {
                        Label("拍照", systemImage: "camera")
                    }
                    Button(action: { store.add("相册图片.png") }) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                }
                Section(header: SettingSectionHeader(title: "已添加 (\(store.items.count))")) {
                    if store.items.isEmpty {
                        Text("暂无附件").foregroundColor(.secondary)
                    } else {
                        ForEach(store.items, id: \.self) { name in
                            Label(name, systemImage: "paperclip")
                        }
                        Button(action: { store.items.removeAll() }) {
                            Text("清空").foregroundColor(.red)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("附件")
            .toolbar {
                Button("完成") { isPresented = false }
            }
            .sheet(isPresented: $showImporter) {
                DocumentImporter { url in
                    store.add(url.lastPathComponent)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 自动化中心（原版 AutomationCenterView）

struct AutomationCenterView: View {
    @ObservedObject private var store = AutomationStore.shared
    @State private var showEditor = false
    @State private var editing: AutomationStore.Task?

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "任务列表")) {
                    if store.tasks.isEmpty {
                        Text("暂无自动化任务")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.tasks) { t in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name)
                                    Text("\(t.schedule) · \(t.action)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { t.enabled },
                                    set: { AutomationStore.shared.setEnabled(t, enabled: $0) }
                                )).labelsHidden()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = t }
                        }
                        .onDelete { offsets in
                            let tasks = offsets.map { store.tasks[$0] }
                            tasks.forEach { AutomationStore.shared.remove($0) }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "最近执行")) {
                    let history = store.history.prefix(20)
                    if history.isEmpty {
                        Text("暂无执行记录").foregroundColor(.secondary)
                    } else {
                        ForEach(Array(history), id: \.id) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.detail).font(.subheadline)
                                Text("\(e.category) · \(ConversationTranscriptView.tf.string(from: e.timestamp))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("自动化中心")
            .toolbar {
                Button(action: {
                    editing = AutomationStore.Task(name: "", schedule: "*/5 * * * *", action: "ping")
                }) { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { task in
                AutomationTaskEditor(task: task)
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct AutomationTaskEditor: View {
    @ObservedObject private var store = AutomationStore.shared
    @State var task: AutomationStore.Task
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: SettingSectionHeader(title: "任务")) {
                    TextField("名称", text: $task.name)
                    TextField("调度（cron / 描述）", text: $task.schedule)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                    TextField("动作（工具调用）", text: $task.action)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                    Toggle("启用", isOn: $task.enabled)
                }
                Section {
                    Button("保存") {
                        if let idx = store.tasks.firstIndex(where: { $0.id == task.id }) {
                            store.tasks[idx] = task
                        } else {
                            store.tasks.append(task)
                        }
                        store.save()
                        AuditLog.shared.log("automation", detail: "保存任务 \(task.name)")
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle(task.name.isEmpty ? "新任务" : task.name)
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 自动化权限（原版 AutomationPermissionsView）

struct AutomationPermissionsView: View {
    @ObservedObject private var store = AutomationStore.shared
    @State private var globalEnabled = true

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "总开关")) {
                    Toggle("允许自动化执行", isOn: $globalEnabled)
                }
                Section(header: SettingSectionHeader(title: "按任务控制")) {
                    if store.tasks.isEmpty {
                        Text("暂无任务").foregroundColor(.secondary)
                    } else {
                        ForEach(store.tasks) { t in
                            Toggle(t.name, isOn: Binding(
                                get: { t.enabled },
                                set: { AutomationStore.shared.setEnabled(t, enabled: $0) }
                            ))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("自动化权限")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Gateway 设置（原版 GatewaySettingsView / GatewayEditorView）

struct GatewayServer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var token: String = ""
}

final class GatewayServerStore: ObservableObject {
    static let shared = GatewayServerStore()
    @Published var servers: [GatewayServer] = []
    private let key = "trollmcp2.gateway_servers"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([GatewayServer].self, from: data) {
            servers = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct GatewaySettingsView: View {
    @ObservedObject private var store = GatewayServerStore.shared
    @State private var editing: GatewayServer?

    var body: some View {
        NavigationView {
            List {
                if store.servers.isEmpty {
                    Text("暂无 Gateway 服务端，点右上角 + 添加")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.servers) { s in
                        NavigationLink(destination: GatewayEditorView(server: s)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                Text(s.url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.servers.remove(atOffsets: offsets)
                        store.save()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Gateway 设置")
            .toolbar {
                Button(action: { editing = GatewayServer(name: "", url: "ws://") }) { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { server in
                GatewayEditorView(server: server)
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct GatewayEditorView: View {
    @ObservedObject private var store = GatewayServerStore.shared
    @State var server: GatewayServer
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: SettingSectionHeader(title: "服务端")) {
                    TextField("名称", text: $server.name)
                    TextField("ws://host:port", text: $server.url)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField("配对令牌（可选）", text: $server.token)
                }
                Section {
                    Button("保存并连接") {
                        if let idx = store.servers.firstIndex(where: { $0.id == server.id }) {
                            store.servers[idx] = server
                        } else {
                            store.servers.append(server)
                        }
                        store.save()
                        GatewayClient.shared.pairedToken = server.token.isEmpty ? nil : server.token
                        GatewayClient.shared.connect(url: server.url)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle(server.name.isEmpty ? "新服务端" : server.name)
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 注入详情（原版 InjectionDetailView）

struct InjectionDetailView: View {
    @State var bundleId: String
    @State private var info: [String: Any] = [:]
    @State private var message = ""

    init(bundleId: String = "") {
        _bundleId = State(initialValue: bundleId)
    }

    var body: some View {
        NavigationView {
            List {
                if bundleId.isEmpty {
                    Section(header: SettingSectionHeader(title: "选择 App")) {
                        ForEach(AppCatalog.list().prefix(100)) { app in
                            Button(action: {
                                bundleId = app.bundleId
                                reload()
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.bundleId)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    detailBody
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("注入详情")
        }
        .navigationViewStyle(.stack)
    }

    private var detailBody: some View {
        Group {
                Section(header: SettingSectionHeader(title: "App")) {
                    LabeledRow(label: "Bundle ID", value: bundleId)
                    if let app = AppCatalog.find(bundleId) {
                        LabeledRow(label: "名称", value: app.name)
                        LabeledRow(label: "路径", value: app.path)
                    }
                }
                Section(header: SettingSectionHeader(title: "注入状态")) {
                    if info.isEmpty {
                        Text("加载中…").foregroundColor(.secondary)
                    } else {
                        ForEach(info.keys.sorted(), id: \.self) { key in
                            LabeledRow(label: key, value: String(describing: info[key] ?? "-"))
                        }
                    }
                }
                Section(header: SettingSectionHeader(title: "操作")) {
                    Button(action: {
                        do {
                            _ = try InjectionManager.shared.enable(bundleId: bundleId, dylibName: "@executable_path/TrollMCPAgent.dylib")
                            message = "已启用注入"
                            reload()
                        } catch { message = "失败: \(error.localizedDescription)" }
                    }) { Text("启用注入").foregroundColor(.green) }
                    Button(action: {
                        do {
                            _ = try InjectionManager.shared.disable(bundleId: bundleId)
                            message = "已禁用注入"
                            reload()
                        } catch { message = "失败: \(error.localizedDescription)" }
                    }) { Text("禁用注入").foregroundColor(.orange) }
                    Button(action: {
                        do {
                            _ = try InjectionRemoveTool().invoke(["bundle_id": bundleId])
                            message = "已彻底移除"
                            reload()
                        } catch { message = "失败: \(error.localizedDescription)" }
                    }) { Text("彻底移除").foregroundColor(.red) }
                }
                if !message.isEmpty {
                    Section { Text(message).font(.caption).foregroundColor(.secondary) }
                }
            }
            .onAppear(perform: reload)
        }

    private func reload() {
        info = InjectionManager.shared.inspect(bundleId)
    }
}

// MARK: - 设置活动记录（原版 SettingsActivityView）

struct SettingsActivityView: View {
    @ObservedObject private var audit = AuditLog.shared
    @State private var filter = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    TextField("按类别过滤", text: $filter)
                        .autocapitalization(.none)
                }
                Section(header: SettingSectionHeader(title: "活动记录")) {
                    let entries = filter.isEmpty ? audit.entries : audit.entries.filter { $0.category.contains(filter) }
                    if entries.isEmpty {
                        Text("暂无记录").foregroundColor(.secondary)
                    } else {
                        ForEach(entries) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(e.category)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(e.level == .error ? .red : (e.level == .warning ? .orange : .blue))
                                    Spacer()
                                    Text(ConversationTranscriptView.tf.string(from: e.timestamp))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(e.detail).font(.subheadline)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("活动记录")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Skill / Agent 编辑器（原版 SkillEditorView / AgentEditorView）

struct SkillEditorView: View {
    @State private var name = ""
    @State private var instruction = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: SettingSectionHeader(title: "Skill")) {
                    TextField("名称", text: $name)
                    TextEditor(text: $instruction)
                        .frame(minHeight: 120)
                }
                Section {
                    Button("保存到 skills.json") {
                        Self.upsert(file: "skills.json", entry: ["name": name, "instruction": instruction])
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle("新建 Skill")
        }
        .navigationViewStyle(.stack)
    }

    static func upsert(file: String, entry: [String: String]) {
        let kb = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("KnowledgeBase")
        try? FileManager.default.createDirectory(at: kb, withIntermediateDirectories: true)
        let url = kb.appendingPathComponent(file)
        var list: [[String: String]] = []
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            list = json
        }
        if let name = entry["name"], let idx = list.firstIndex(where: { $0["name"] == name }) {
            list[idx] = entry
        } else {
            list.append(entry)
        }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: .prettyPrinted) {
            try? data.write(to: url)
        }
        AuditLog.shared.log("skills", detail: "保存 \(entry["name"] ?? "")")
    }
}

struct AgentEditorView: View {
    @State private var name = ""
    @State private var systemPrompt = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: SettingSectionHeader(title: "Agent")) {
                    TextField("名称", text: $name)
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 120)
                }
                Section {
                    Button("保存到 agents.json") {
                        SkillEditorView.upsert(file: "agents.json", entry: ["name": name, "systemPrompt": systemPrompt])
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle("新建 Agent")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Webhook 编辑器（原版 WebhookEditorView）

struct WebhookEditorView: View {
    @State private var url = ""
    @State private var secret = ""
    @State private var events = "audit,tool_call"
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: SettingSectionHeader(title: "端点")) {
                    TextField("https://example.com/webhook", text: $url)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField("签名密钥（可选）", text: $secret)
                    TextField("事件列表（逗号分隔）", text: $events)
                        .autocapitalization(.none)
                }
                Section {
                    Button("保存") {
                        UserDefaults.standard.set(["url": url, "secret": secret, "events": events], forKey: "trollmcp2.webhook")
                        AuditLog.shared.log("webhook", detail: "保存 \(url)")
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle("Webhook 编辑")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - API Key 恢复表（原版 APIKeyRecoverySheet）

struct APIKeyRecoverySheet: View {
    @ObservedObject private var models = ModelStore.shared
    @State private var revealed: UUID?
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "已保存的密钥")) {
                    if models.configs.isEmpty {
                        Text("暂无模型配置").foregroundColor(.secondary)
                    } else {
                        ForEach(models.configs) { c in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                    Text(masked(c))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if revealed == c.id {
                                    Button("隐藏") { revealed = nil }.font(.caption)
                                } else {
                                    Button("显示") { revealed = c.id }.font(.caption)
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("密钥仅保存在本机 UserDefaults，不会上传。恢复到新设备需重新输入。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("API Key")
            .toolbar { Button("完成") { presentationMode.wrappedValue.dismiss() } }
        }
        .navigationViewStyle(.stack)
    }

    private func masked(_ c: ModelConfig) -> String {
        guard !c.apiKey.isEmpty else { return "(空)" }
        if revealed == c.id { return c.apiKey }
        if c.apiKey.count > 8 {
            return String(c.apiKey.prefix(4)) + "****" + String(c.apiKey.suffix(4))
        }
        return "****"
    }
}

// MARK: - 上游模型选择（原版 UpstreamModelPickerView）

struct UpstreamModelPickerView: View {
    @ObservedObject private var models = ModelStore.shared
    @State private var upstream: [String] = []
    @State private var loading = false
    @State private var errorText = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if !errorText.isEmpty {
                    Text(errorText).foregroundColor(.red).font(.caption)
                } else if upstream.isEmpty {
                    Text("点右上角刷新获取上游模型列表").foregroundColor(.secondary)
                } else {
                    Section(header: SettingSectionHeader(title: "上游模型")) {
                        ForEach(upstream, id: \.self) { id in
                            Button(action: {
                                if var c = models.defaultConfig {
                                    c.model = id
                                    models.update(c)
                                }
                            }) {
                                HStack {
                                    Text(id).font(.system(.subheadline, design: .monospaced))
                                    Spacer()
                                    if models.defaultConfig?.model == id {
                                        Image(systemName: "checkmark").foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("上游模型")
            .toolbar {
                Button(action: fetch) { Image(systemName: "arrow.clockwise") }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func fetch() {
        guard let config = models.defaultConfig else {
            errorText = "请先配置模型 API"
            return
        }
        loading = true
        errorText = ""
        ModelAPIClient.shared.fetchModelList(config: config) { result in
            loading = false
            switch result {
            case .success(let list): upstream = list
            case .failure(let err): errorText = err
            }
        }
    }
}
