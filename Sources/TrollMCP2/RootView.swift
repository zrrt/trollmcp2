import SwiftUI

struct ToolCard: Identifiable, Hashable {
    let name: String
    let icon: String
    var id: String { name }
}

struct RootView: View {
    @State private var useGrid = true

    private let homeCards: [ToolCard] = [
        ToolCard(name: "会话", icon: "message.fill"),
        ToolCard(name: "工具", icon: "wrench.and.screwdriver.fill"),
        ToolCard(name: "注入", icon: "syringe.fill"),
        ToolCard(name: "编译", icon: "hammer.fill"),
        ToolCard(name: "自动化", icon: "bolt.fill"),
        ToolCard(name: "网关", icon: "network"),
        ToolCard(name: "系统能力", icon: "gearshape.2.fill"),
        ToolCard(name: "审计日志", icon: "doc.text.magnifyingglass"),
        ToolCard(name: "模型", icon: "cpu.fill"),
        ToolCard(name: "设置", icon: "gearshape.fill"),
    ]

    var body: some View {
        TabView {
            homeTab
                .tabItem { Label("首页", systemImage: "house.fill") }
            ChatView()
                .tabItem { Label("会话", systemImage: "message.fill") }
            ToolsView()
                .tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
            InjectionView()
                .tabItem { Label("注入", systemImage: "syringe") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }

    private var homeTab: some View {
        NavigationView {
            Group {
                if useGrid {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 18
                        ) {
                            ForEach(homeCards) { card in
                                NavigationLink(destination: destination(for: card.name)) {
                                    VStack(spacing: 8) {
                                        Image(systemName: card.icon)
                                            .font(.system(size: 28))
                                            .frame(height: 34)
                                        Text(card.name)
                                            .font(.footnote)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(14)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                } else {
                    List(homeCards) { card in
                        NavigationLink(destination: destination(for: card.name)) {
                            Label(card.name, systemImage: card.icon)
                        }
                    }
                }
            }
            .navigationTitle("TrollMCP 2")
            .toolbar {
                Button(useGrid ? "列表" : "网格") {
                    useGrid.toggle()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func destination(for name: String) -> some View {
        switch name {
        case "会话": ChatView()
        case "工具": ToolsView()
        case "注入": InjectionView()
        case "编译": BuildView()
        case "自动化": AutomationView()
        case "网关": GatewayView()
        case "系统能力": SystemCapabilitiesView()
        case "审计日志": AuditLogView()
        case "模型": ModelsView()
        case "设置": SettingsView()
        default: EmptyView()
        }
    }
}

struct ToolsView: View {
    private let defs = ToolRegistry.shared.definitions

    var body: some View {
        NavigationView {
            List(defs, id: \.name) { def in
                VStack(alignment: .leading, spacing: 4) {
                    Text(def.name)
                        .font(.system(.body, design: .monospaced))
                    Text(def.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("MCP 工具 (\(defs.count))")
        }
        .navigationViewStyle(.stack)
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("模型")) {
                    NavigationLink("模型配置") { ModelsView() }
                }
                Section(header: Text("连接")) {
                    NavigationLink("网关") { GatewayView() }
                    NavigationLink("自动化") { AutomationView() }
                }
                Section(header: Text("工具")) {
                    NavigationLink("注入管理") { InjectionView() }
                    NavigationLink("编译模式") { BuildView() }
                    NavigationLink("系统能力") { SystemCapabilitiesView() }
                }
                Section(header: Text("日志")) {
                    NavigationLink("审计日志") { AuditLogView() }
                }
                Section(header: Text("关于")) {
                    LabeledRow(label: "版本", value: "2.0.0")
                    LabeledRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "-")
                    LabeledRow(label: "工作区", value: Workspace.root.lastPathComponent)
                    LabeledRow(label: "工具数", value: "\(ToolRegistry.shared.definitions.count)")
                }
            }
            .navigationTitle("设置")
        }
        .navigationViewStyle(.stack)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.system(.footnote, design: .monospaced))
        }
    }
}
