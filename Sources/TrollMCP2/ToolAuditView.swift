import SwiftUI

struct ToolAuditView: View {
    @ObservedObject private var registry = ToolRegistry.shared
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
        "workspace.outputName"
    ]

    private var definitions: [ToolDefinition] {
        let list = registry.definitions
        if showOnlyReal {
            return list.filter { realTools.contains($0.name) }
        }
        return list
    }

    var body: some View {
        List {
            Section(header: SettingSectionHeader(title: "审计过滤")) {
                Toggle("仅显示真实实现", isOn: $showOnlyReal)
            }

            Section(header: SettingSectionHeader(title: "已注册工具（\(definitions.count)）")) {
                ForEach(definitions, id: \.name) { def in
                    ToolAuditRow(def: def, isReal: realTools.contains(def.name))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("本机工具审计")
    }
}

struct ToolAuditRow: View {
    let def: ToolDefinition
    let isReal: Bool
    @ObservedObject private var registry = ToolRegistry.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(def.name)
                        .font(.system(.body, design: .monospaced))
                    Text(isReal ? "真实" : "占位")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isReal ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .foregroundColor(isReal ? .green : .orange)
                        .cornerRadius(4)
                }
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
