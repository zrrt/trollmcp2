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

/// v2.9.158：App 图标加载器——对齐 TrollFools 用系统缓存图标私有 API
/// `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]`（能拿到
/// Assets.car 里的图标，系统级缓存持久），NSCache 防重复读取；失败回退首字母占位。
final class AppIconLoader {
    static let shared = AppIconLoader()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 512 }

    func icon(for bundleId: String) -> UIImage? {
        let key = bundleId as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var img: UIImage?
        let cls: AnyClass = UIImage.self
        let sel = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
        if cls.responds(to: sel) {
            typealias IconFn = @convention(c) (AnyClass, Selector, NSString, Int, CGFloat) -> UIImage?
            let fn = unsafeBitCast(class_getMethodImplementation(cls, sel), to: IconFn.self)
            img = fn(cls, sel, bundleId as NSString, 0, 3.0)
        }
        if let img = img { cache.setObject(img, forKey: key) }
        return img
    }
}

struct AppIconView: View {
    let bundleId: String

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
            let img = AppIconLoader.shared.icon(for: bundleId)
            DispatchQueue.main.async {
                image = img
            }
        }
    }
}
