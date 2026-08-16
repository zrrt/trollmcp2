import SwiftUI

struct InjectionView: View {
    @State private var apps: [AppCatalog.AppEntry] = []
    @State private var searchText = ""
    @State private var useGrid = true
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
                } else if useGrid {
                    appGrid
                } else {
                    appList
                }
            }
            .navigationTitle("注入管理 (\(apps.count))")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(useGrid ? "列表" : "网格") { useGrid.toggle() }
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                }
            }
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app, inspectResult: $inspectResult)
            }
        }
        .navigationViewStyle(.stack)
    }

    private var appGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(filtered) { app in
                    Button(action: { selectedApp = app; inspectApp(app) }) {
                        VStack(spacing: 8) {
                            Image(systemName: "app.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.blue)
                            Text(app.name)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private var appList: some View {
        List(filtered) { app in
            Button(action: { selectedApp = app; inspectApp(app) }) {
                VStack(alignment: .leading) {
                    Text(app.name).font(.body)
                    Text(app.bundleId).font(.caption).foregroundColor(.secondary)
                }
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

    private struct DictEntry: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    private var entries: [DictEntry] {
        (inspectResult ?? [:]).sorted { $0.key < $1.key }
            .map { DictEntry(key: $0.key, value: "\($0.value)") }
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("应用信息")) {
                    LabeledRow(label: "名称", value: app.name)
                    LabeledRow(label: "Bundle ID", value: app.bundleId)
                    LabeledRow(label: "路径", value: app.path)
                    if let container = app.containerPath {
                        LabeledRow(label: "容器", value: container)
                    }
                }
                Section(header: Text("注入工具链")) {
                    ForEach(InjectionManager.shared.availableBinaries(), id: \.self) { bin in
                        Label(bin, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                if !entries.isEmpty {
                    Section(header: Text("检查结果")) {
                        ForEach(entries) { e in
                            LabeledRow(label: e.key, value: e.value)
                        }
                    }
                }
            }
            .navigationTitle(app.name)
            .toolbar { Button("关闭") { presentationMode.wrappedValue.dismiss() } }
        }
    }
}
