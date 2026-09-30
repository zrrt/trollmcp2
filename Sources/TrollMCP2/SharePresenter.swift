import SwiftUI
import UIKit

/// v4.3.46：统一分享器——TrollStore 侧载环境"分享面板闪退"最终方案。
///
/// 崩溃铁证（sig_1790791863 与 sig_1790797823，两次真机崩溃栈地址逐字节相同）：
/// ShareSheet → SharingUI → UIKitCore → **MobileIcons(LICreateIconForImages) → CoreImage →
/// Segmentation fault: 11**。崩溃发生在系统分享框架内部——枚举"支持当前内容类型的所有
/// 分享扩展"并生成扩展图标时。任何触达系统分享面板的路径（手写 UIActivityViewController /
/// SwiftUI ShareLink / QLPreviewController 系统分享按钮 / .quickLookPreview 预览页分享按钮）
/// 都在同一地址崩溃，与呈现方式无关。
///
/// 对照：TrollFools 分享 .dylib（第三方扩展均不支持）→ 面板只枚举系统扩展 → 不崩；
/// 我们分享 .txt/普通文件 → ShareSheet 枚举全部第三方扩展图标 → 必崩。
/// → 结论：本设备侧载环境下**任何系统分享面板都不可用**。
///
/// 最终方案：**自建分享菜单**（ShareCenter.presentShareMenuFile/Text），
/// 选项：拷贝 / 存储到文件（UIDocumentPicker）/ 用其他 App 打开（UIDocumentInteractionController），
/// 全部绕开 ShareSheet，侧载环境安全。
enum SharePresenter {

    /// 命令式分享入口（兼容 UpdateManager / MoreViews Alert 等非 View 上下文调用点）。
    /// 文件 → 自建文件分享菜单；纯文字 → 自建文字分享菜单；均不触达系统分享面板。
    static func present(
        _ items: [Any],
        excluded: [UIActivity.ActivityType] = [],
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            var fileURLs: [URL] = []
            var texts: [String] = []

            for item in items {
                if let url = item as? URL, url.isFileURL {
                    if FileManager.default.fileExists(atPath: url.path) {
                        fileURLs.append(url)
                    } else {
                        AuditLog.shared.log("share.invalid_url", detail: url.path)
                    }
                } else if let s = item as? String {
                    texts.append(s)
                }
            }

            if let file = fileURLs.first {
                AuditLog.shared.log("share.menu_file", detail: file.lastPathComponent)
                ShareCenter.shared.presentShareMenuFile(file)
                completion?(true, nil)
                return
            }

            if !texts.isEmpty {
                AuditLog.shared.log("share.menu_text", detail: "texts=\(texts.count)")
                ShareCenter.shared.presentShareMenuText(texts.joined(separator: "\n"))
                completion?(true, nil)
                return
            }

            AuditLog.shared.log("share.all_invalid", detail: "items=\(items.count)")
            completion?(false, NSError(domain: "SharePresenter", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: "分享内容无效"]))
        }
    }
}

// MARK: - SwiftUI 分享入口（v4.3.46 最终方案：自建菜单，绕开 ShareSheet）
//
// 崩溃铁证：任何触达系统分享面板的路径（ShareLink / UIActivityViewController /
// QLPreviewController 分享按钮）在本设备侧载环境都在 MobileIcons/CoreImage 同一地址
// SIGSEGV（sig_1790791863 与 sig_1790797823 栈帧地址逐字节相同）。
// 因此全部分享入口改为触发 ShareCenter 自建菜单（拷贝 / 存储到文件 / 用其他 App 打开），
// 彻底不经过 ShareSheet。
extension SharePresenter {

    /// 上下文菜单里的"分享"项（文件 URL）→ 自建分享菜单
    static func menuShare(url: URL,
                          label: String = "分享",
                          systemImage: String = "square.and.arrow.up") -> some View {
        Button {
            ShareCenter.shared.presentShareMenuFile(url)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    /// 上下文菜单里的"分享"项（文本）→ 自建分享菜单
    static func menuShare(text: String,
                          label: String = "分享",
                          systemImage: String = "square.and.arrow.up") -> some View {
        Button {
            ShareCenter.shared.presentShareMenuText(text)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    /// 工具栏里的"分享"图标按钮（文本）→ 自建分享菜单
    static func toolbarShare(text: String) -> some View {
        Button {
            ShareCenter.shared.presentShareMenuText(text)
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
        }
    }

    /// 工具栏里的"分享"图标按钮（文件 URL）→ 自建分享菜单
    static func toolbarShare(url: URL) -> some View {
        Button {
            ShareCenter.shared.presentShareMenuFile(url)
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
        }
    }
}
