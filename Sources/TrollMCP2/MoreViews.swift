import SwiftUI

struct AuditLogView: View {
    @ObservedObject private var log = AuditLog.shared
    @State private var useGrid = false

    var body: some View {
        NavigationView {
            List {
                ForEach(log.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.category)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(levelColor(entry.level))
                            Spacer()
                            Text(timeString(entry.timestamp))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
            }
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
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

struct BuildView: View {
    @State private var token = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("编译模式")) {
                    Button("生成编译令牌") {
                        if let result = try? ToolRegistry.shared.dispatch(name: "build.runner.token", params: ["action": "generate"]),
                           let t = result["token"] as? String {
                            token = t
                        }
                    }
                    if !token.isEmpty {
                        Text(token)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                }
                Section(header: Text("项目模板")) {
                    Button("生成 Tweak 项目模板") {
                        _ = try? ToolRegistry.shared.dispatch(name: "project.generate_tweak", params: ["name": "MyTweak"])
                    }
                }
                Section(header: Text("说明")) {
                    Text("编译模式允许在 iPhone 上编译 dylib。需要已注入 TMBuildAgent.dylib 到 TrollMCP。编译令牌用于验证编译请求。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("编译")
        }
        .navigationViewStyle(.stack)
    }
}

struct SystemCapabilitiesView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("系统能力")) {
                    capRow("通讯录搜索", "contacts.search", "person.crop.circle")
                    capRow("日历事件", "calendar.list", "calendar")
                    capRow("提醒事项", "reminder.create", "checkmark.square")
                    capRow("定位", "location.get", "location")
                    capRow("本地通知", "notification.send", "bell")
                    capRow("扫码识别", "scan.qr", "qrcode.viewfinder")
                    capRow("进程枚举", "process.list", "list.bullet")
                }
            }
            .navigationTitle("系统能力")
        }
        .navigationViewStyle(.stack)
    }

    private func capRow(_ name: String, _ tool: String, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundColor(.blue)
            Text(name)
            Spacer()
            Text(tool)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}
