import SwiftUI

// v2.9.128：应用选择（Fuck 工具箱风格：分类标签+版本+类型胶囊+A-Z 索引）
struct AppPickerView: View {
    @Environment(\.presentationMode) var presentationMode
    var onSelect: ((AppCatalog.AppEntry) -> Void)?

    var body: some View {
        NavigationView {
            AppBrowserContainer(
                title: "选择应用",
                subtitle: "搜索 · 分类 · 版本 · 索引",
                icon: "app.badge.fill",
                onTap: { app in
                    onSelect?(app)
                    presentationMode.wrappedValue.dismiss()
                }
            )
            .navigationTitle("选择应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
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
