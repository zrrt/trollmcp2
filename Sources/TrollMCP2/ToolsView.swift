import SwiftUI

struct ToolsView: View {
    private let defs = ToolRegistry.shared.definitions

    private var grouped: [(String, [ToolDefinition])] {
        let categories: [(String, String, [String])] = [
            ("文件桥", "folder", ["artifact.read_text", "artifact.write_text", "artifact.list", "workspace.info"]),
            ("注入管理", "syringe", ["injection.enable", "injection.disable", "injection.restore", "rescue.scan", "rescue.recover_all", "rescue.cleanup", "injection.status", "injection.inspect", "injection.list", "container.write_text"]),
            ("Gateway", "network", ["gateway.status", "gateway.connect", "node.invoke", "cron.fire"]),
            ("自动化", "bolt", ["automation.run", "automation.list", "automation.stop", "automation.status"]),
            ("系统能力", "gearshape.2", ["contacts.search", "calendar.list", "reminder.create", "location.get", "notification.send", "scan.qr", "process.list"]),
            ("编译与模型", "hammer", ["build.runner.token", "project.generate_tweak", "model.config", "ping", "device.info"])
        ]
        let map = Dictionary(uniqueKeysWithValues: defs.map { ($0.name, $0) })
        return categories.compactMap { cat, _, names in
            let items = names.compactMap { map[$0] }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(grouped, id: \.0) { section in
                    Section(header: SettingSectionHeader(title: section.0)) {
                        ForEach(section.1, id: \.name) { def in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(def.name)
                                    .font(.system(.body, design: .monospaced))
                                Text(def.summary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("MCP 工具 (\(defs.count))")
        }
        .navigationViewStyle(.stack)
    }
}
