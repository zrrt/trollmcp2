import SwiftUI
import UIKit

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

/// v2.9.162：App 图标加载器——v2.9.161 之前用私有 API
/// `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]`，实测 iOS 16.3
/// 不响应（崩溃日志 exc_*.txt: unrecognized selector → NSInvalidArgumentException → 列表页闪退）。
/// 改用公开 API：读 App 包内 Info.plist 的 CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles，
/// 用 UIImage(contentsOfFile:) 直接加载图标文件（@3x/@2x/无后缀依次尝试）；NSCache 防重复读。
final class AppIconLoader {
    static let shared = AppIconLoader()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 512 }

    func icon(forPath path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = Self.readIcon(from: path)
        if let img = img { cache.setObject(img, forKey: key) }
        return img
    }

    /// 公开 API 读图标文件：解析 App 的 Info.plist 图标名，逐 scale 尝试读取
    private static func readIcon(from appPath: String) -> UIImage? {
        guard let plist = NSDictionary(contentsOfFile: appPath + "/Info.plist") else { return nil }
        var names: [String] = []
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            names = files
        }
        if names.isEmpty, let files = plist["CFBundleIconFiles"] as? [String] {
            names = files
        }
        if names.isEmpty, let legacy = plist["CFBundleIconFile"] as? String {
            names = [legacy]
        }
        guard let base = names.first else { return nil }
        // 依次尝试 @3x / @2x / 无后缀；有的图标文件不带 .png 扩展名
        for (scale, suffix) in [(3.0, "@3x"), (2.0, "@2x"), (1.0, "")] {
            for ext in ["png", ""] {
                let file = base + suffix + (ext.isEmpty ? "" : "." + ext)
                if let img = UIImage(contentsOfFile: appPath + "/" + file) { return img }
            }
        }
        return nil
    }
}

struct AppIconView: View {
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
                    Text(String((path as NSString).lastPathComponent.prefix(1).uppercased()))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear { loadIcon() }
    }

    private func loadIcon() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = AppIconLoader.shared.icon(forPath: path)
            DispatchQueue.main.async {
                image = img
            }
        }
    }
}
