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

    /// 公开 API 读图标文件，命中率从高到低：
    /// 1) Info.plist CFBundleIconFiles 名（老 App 独立 PNG）
    /// 2) 常见图标名 UIImage(named:in:)（能读 Assets.car 里的命名图标）
    /// 3) 顶层 *.png 中面积最大的（排除 Launch/Splash）
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
        // 1) Info.plist 图标名 + 文件系统读取
        for base in names {
            for (scale, suffix) in [(3.0, "@3x"), (2.0, "@2x"), (1.0, "")] {
                for ext in ["png", ""] {
                    let file = base + suffix + (ext.isEmpty ? "" : "." + ext)
                    if let img = UIImage(contentsOfFile: appPath + "/" + file) { return img }
                }
            }
        }
        // 2) 常见编译名（Assets.car 命名资源）
        let bundle = Bundle(path: appPath)
        let common = ["AppIcon60x60@3x", "AppIcon60x60@2x", "AppIcon60x60",
                      "AppIcon@3x", "AppIcon@2x", "AppIcon",
                      "Icon-60@3x", "Icon-60@2x", "Icon-76@2x", "Icon",
                      "icon@3x", "icon@2x", "icon"]
        for name in common {
            if let img = UIImage(named: name, in: bundle, compatibleWith: nil) { return img }
            if let img = UIImage(contentsOfFile: appPath + "/" + name + ".png") { return img }
        }
        // 3) 顶层 *.png 面积最大者（排除启动图/背景图）
        if let files = try? FileManager.default.contentsOfDirectory(atPath: appPath) {
            let candidates = files.filter { $0.hasSuffix(".png") && !$0.lowercased().contains("launch") && !$0.lowercased().contains("splash") }
            var best: (UIImage, CGFloat)? = nil
            for f in candidates {
                guard let img = UIImage(contentsOfFile: appPath + "/" + f) else { continue }
                let area = img.size.width * img.size.height
                if best == nil || area > best!.1 { best = (img, area) }
            }
            if let b = best { return b.0 }
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
