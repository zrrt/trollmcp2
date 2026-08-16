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
                    capRow("定位", "location.get", "location", .indigo)
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
