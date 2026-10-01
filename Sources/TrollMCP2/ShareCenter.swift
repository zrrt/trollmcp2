import SwiftUI
import UIKit

/// v4.3.46：分享中转站——TrollStore 侧载环境"分享面板闪退"的最终方案。
///
/// 崩溃铁证（两次真机崩溃栈地址逐字节相同，sig_1790791863 / sig_1790797823）：
/// ShareSheet → SharingUI → UIKitCore → **MobileIcons(LICreateIconForImages/LICreateIconForImage)
/// → CoreImage → Segmentation fault: 11**。
///
/// **最终根因（v4.3.47 确认）**：TrollAgent 的 Info.plist 曾声明 `CFBundleDocumentTypes =
/// All Files（public.item，支持所有文件类型）`。系统分享面板枚举"支持当前内容类型的所有
/// App/扩展"时，**把 TrollAgent 自己列入**并让 MobileIcons 为它生成图标 —— 侧载环境下
/// TrollAgent 的图标注册异常 → MobileIcons/CoreImage SIGSEGV。
/// 对照：TrollFools 只声明 mach-o/zip/deb 三种类型，分享 ipa/txt 时面板里**没有它自己** → 不崩。
/// **修复**：删除 All Files 声明（v4.3.47），分享面板不再为 TrollAgent 生成图标。
///
/// 兜底：自建分享菜单（拷贝 / 存储到文件 / 用其他 App 打开）绕开 ShareSheet，
/// 任何情况下都可用。
/// 根治方案：**自建分享菜单，彻底绕开 ShareSheet**：
///   1. **拷贝**（UIPasteboard，文字/路径）
///   2. **存储到文件**（UIDocumentPickerViewController(forExporting:) —— Files 保存界面，
///      不枚举分享扩展，安全）
///   3. **用其他 App 打开**（UIDocumentInteractionController.presentOpenInMenu —— 打开方式
///      菜单，Launch Services 列表，不经过 ShareSheet）
final class ShareCenter: ObservableObject {
    static let shared = ShareCenter()

    /// 提示文案（nil = 无提示）
    @Published var clipboardNotice: String?

    private init() {}

    // MARK: - 文件分享：自建菜单（UIKit ActionSheet，绕开 ShareSheet）

    /// 文件分享菜单：存储到文件 / 用其他 App 打开 / 取消
    func presentShareMenuFile(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.showNotice("文件不存在，无法分享")
                return
            }
            let alert = UIAlertController(title: "分享 \(url.lastPathComponent)",
                                          message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "存储到文件", style: .default) { _ in
                self.saveToFiles(url)
            })
            // v4.3.51：移除"用其他 App 打开"——UIDocumentInteractionController.presentOpenInMenu
            // 内部渲染"能打开此文件的全部 App 图标列表"，本设备侧载环境 MobileIcons 渲染
            // 列表图标时 CoreImage SIGSEGV（实测崩溃，与 ShareSheet 同一崩溃点）。
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            Self.anchor(alert)
            Self.topViewController()?.present(alert, animated: true)
        }
    }

    /// 文字分享菜单：拷贝 / 存储到文件（写临时 txt）/ 取消
    func presentShareMenuText(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.showNotice("没有可分享的内容")
                return
            }
            let alert = UIAlertController(title: "分享", message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "拷贝", style: .default) { _ in
                self.fallbackClipboard(trimmed)
            })
            alert.addAction(UIAlertAction(title: "存储到文件", style: .default) { _ in
                if let url = Self.writeTextToTemp(trimmed) {
                    self.saveToFiles(url)
                } else {
                    self.fallbackClipboard(trimmed)
                }
            })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            Self.anchor(alert)
            Self.topViewController()?.present(alert, animated: true)
        }
    }

    // MARK: - 存储到文件（UIDocumentPicker，安全路径）

    /// 存储到文件：UIDocumentPickerViewController(forExporting:) 弹出 Files 保存界面。
    /// 不经过 ShareSheet，不枚举分享扩展，侧载环境安全。
    func saveToFiles(_ url: URL) {
        // 延迟 0.45s：contextMenu 按钮点击后 dismiss 动画约 0.5s，立即 present 会被吞
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.showNotice("文件不存在，无法保存")
                return
            }
            guard let top = Self.topViewController() else { return }
            let picker = UIDocumentPickerViewController(forExporting: [url])
            picker.modalPresentationStyle = .fullScreen
            top.present(picker, animated: true)
            AuditLog.shared.log("share.save_to_files", detail: url.lastPathComponent)
        }
    }

    // MARK: - 用其他 App 打开（UIDocumentInteractionController，安全路径）

    /// v4.3.51：用 TrollStore 安装（URL scheme 直调，不渲染任何 App 图标列表）。
    /// TrollStore 注册了 apple-magnifier://install?url= 路由（安装 tipa/ipa 到设备）。
    /// 该路径是系统级 scheme 路由，不经过 MobileIcons 图标列表渲染，侧载环境安全。
    func openInTrollStore(_ url: URL) {
        guard url.pathExtension.lowercased() == "tipa" || url.pathExtension.lowercased() == "ipa" else {
            self.showNotice("仅支持 .tipa/.ipa 文件直接安装")
            return
        }
        guard let base = URL(string: "apple-magnifier://install?url="),
              let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let target = URL(string: base.absoluteString + encoded) else {
            UIPasteboard.general.string = url.path
            self.showNotice("无法直达 TrollStore，已复制文件路径")
            return
        }
        UIApplication.shared.open(target) { ok in
            if !ok {
                UIPasteboard.general.string = url.path
                self.showNotice("未检测到 TrollStore，已复制文件路径")
            }
        }
        AuditLog.shared.log("share.open_in_trollstore", detail: url.lastPathComponent)
    }

    /// v4.3.51 弃用：打开方式列表会渲染 App 图标 → 侧载环境 MobileIcons SIGSEGV。
    /// 保留代码仅供追溯。
    func openIn(_ url: URL) {
        // 延迟 0.45s：contextMenu 按钮点击后 dismiss 动画约 0.5s，立即 present 会被吞
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.showNotice("文件不存在")
                return
            }
            guard let top = Self.topViewController() else { return }
            let doc = UIDocumentInteractionController(url: url)
            objc_setAssociatedObject(top, &Self.docControllerKey, doc, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            doc.delegate = DocInteractionDelegate.shared
            guard let view = top.view else { return }
            let rect = view.bounds
            let ok = doc.presentOpenInMenu(from: rect, in: view, animated: true)
            if !ok {
                self.showNotice("没有 App 能打开此文件")
            }
            AuditLog.shared.log("share.open_in", detail: url.lastPathComponent)
        }
    }
    private static var docControllerKey = "ShareCenterDocControllerKey"

    // MARK: - 文字 → 临时 txt

    /// 把文字写入临时 txt 文件，返回 URL；失败返回 nil。
    static func writeTextToTemp(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefix = String(trimmed.prefix(12))
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = "分享_\(prefix.isEmpty ? "文本" : prefix)_\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try trimmed.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 拷贝兜底

    /// 纯文字/链接复制兜底
    func fallbackClipboard(_ text: String) {
        UIPasteboard.general.string = text
        showNotice("已复制到剪贴板")
        AuditLog.shared.log("share.fallback_clipboard", detail: "texts=1")
    }

    private func showNotice(_ text: String) {
        DispatchQueue.main.async {
            self.clipboardNotice = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.clipboardNotice = nil
            }
        }
    }

    /// iPad 兼容：actionSheet 需要 popover 锚点
    static func anchor(_ alert: UIAlertController) {
        guard let vc = topViewController(), let view = vc.view else { return }
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
        alert.popoverPresentationController?.permittedArrowDirections = []
    }

    /// 找到当前最顶层 UIViewController（绕开 SwiftUI 层级，直接往 key window 上 present）
    static func topViewController() -> UIViewController? {
        var vc: UIViewController?
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        } else if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        }
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }
}

/// UIDocumentInteractionController 代理（分享菜单点开后需要保留 delegate 存活）
private final class DocInteractionDelegate: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = DocInteractionDelegate()
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        ShareCenter.topViewController() ?? UIViewController()
    }
}
