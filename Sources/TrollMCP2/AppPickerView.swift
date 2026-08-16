import SwiftUI

struct AppPickerView: View {
    @Environment(\.presentationMode) var presentationMode
    var onSelect: ((AppCatalog.AppEntry) -> Void)?

    @State private var apps: [AppCatalog.AppEntry] = []
    @State private var searchText = ""

    private var filtered: [AppCatalog.AppEntry] {
        if searchText.isEmpty { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleId.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                List {
                    Section(header: HStack {
                        Text("已安装应用")
                        Spacer()
                        Text("\(apps.count)")
                            .foregroundColor(.secondary)
                    }) {
                        ForEach(filtered) { app in
                            Button(action: {
                                onSelect?(app)
                                presentationMode.wrappedValue.dismiss()
                            }) {
                                HStack(spacing: 12) {
                                    AppIconView(bundleId: app.bundleId, path: app.path)
                                        .frame(width: 44, height: 44)
                                        .cornerRadius(10)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(app.bundleId)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("选择应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { loadApps() }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索名称或 Bundle ID", text: $searchText)
                .font(.body)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func loadApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppCatalog.list()
            DispatchQueue.main.async {
                apps = list
            }
        }
    }
}

struct AppIconView: View {
    let bundleId: String
    let path: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    Text(String(bundleId.prefix(1).uppercased()))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear { loadIcon() }
    }

    private func loadIcon() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let info = Bundle(path: path)?.infoDictionary,
                  let icons = info["CFBundleIcons"] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String],
                  let last = files.last else { return }
            let iconPath = (path as NSString).appendingPathComponent(last + "@2x.png")
            let img = UIImage(contentsOfFile: iconPath) ?? UIImage(contentsOfFile: (path as NSString).appendingPathComponent(last + ".png"))
            DispatchQueue.main.async {
                image = img
            }
        }
    }
}
