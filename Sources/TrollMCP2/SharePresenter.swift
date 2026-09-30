import SwiftUI
import UIKit
import QuickLook

/// v4.3.41：统一分享器——优先弹出 iOS 系统完整分享页 UIActivityViewController
/// （微信/短信/隔空投送/存储到文件/用 TrollStore 打开/复制 等全部活动项）。
///
/// ⚠️ v4.3.44 重大变更：TrollStore(巨魔)侧载环境下**手写 present UIActivityViewController
/// 会触发系统级 SIGSEGV 崩溃**（崩溃栈实证：ShareSheet → MobileIcons/LICreateIconForImages →
/// CoreImage → Segmentation fault: 11）。崩溃发生在系统框架内部（枚举分享扩展并生成目标图标时），
/// 无论怎么调整 present 时机/防重入/转场等待都无法规避——v4.3.43 的加固已被真机证伪。
///
/// 根治方案（照抄 TrollStore 生态 App **TrollFools** 的稳定做法，已获用户批准）：
/// 1. **iOS 16.4+**：SwiftUI 原生 `ShareLink`——由系统在正确的 window scene 与宿主上下文
///    呈现分享面板，不经过手写 keyWindow/顶层VC 查找（TrollFools 源码 PlugInCell.swift /
///    EjectListView.swift 实测同款）；
/// 2. **iOS 16.4 以下**：**QuickLook 预览中间层**——命令式路径一律先弹 QLPreviewController
///    （由 ShareCenter 显式 fullScreenCover 呈现，导航栏自带系统分享按钮），用户在预览页
///    点系统分享按钮，由系统在自己安全上下文里弹分享面板，彻底绕开手写 UIActivityViewController
///    枚举分享扩展的崩溃路径。（TrollFools：`quickLookExport = url` + `.quickLookPreview`）
///
/// 纯文字（无文件可预览）兜底：复制到剪贴板 + 提示。
enum SharePresenter {
    /// 防重入锁（保留 v4.3.43 语义）：同一时刻只允许一个分享页在弹。
    private static var isPresenting = false

    /// v4.3.44：命令式分享入口——侧载环境安全路径。
    ///
    /// - 分享项含**文件 URL** → QuickLook 中间层（ShareCenter 显式 fullScreenCover 呈现），
    ///   由系统在预览页呈现分享面板，**不再手写 present UIActivityViewController**；
    /// - 纯**文字/链接** → 复制到剪贴板并提示（无文件可预览时的安全降级）；
    /// - 无法分享 → 返回错误。
    ///
    /// 兼容性：UpdateManager（非 View 上下文）、Alert 回调等命令式调用点统一走此入口。
    static func present(
        _ items: [Any],
        excluded: [UIActivity.ActivityType] = [],
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            if Self.isPresenting {
                AuditLog.shared.log("share.busy", detail: "items=\(items.count)")
                completion?(false, NSError(domain: "SharePresenter", code: -3,
                                           userInfo: [NSLocalizedDescriptionKey: "分享页已打开"]))
                return
            }

            // 收集有效分享项：文件 URL 需真实存在；文本、链接、其他对象分别归类
            var fileURLs: [URL] = []
            var texts: [String] = []
            var otherCount = 0

            for item in items {
                if let url = item as? URL, url.isFileURL {
                    if FileManager.default.fileExists(atPath: url.path) {
                        fileURLs.append(url)
                    } else {
                        AuditLog.shared.log("share.invalid_url", detail: url.path)
                    }
                } else if let s = item as? String {
                    texts.append(s)
                } else {
                    otherCount += 1
                }
            }

            // 文件 → QuickLook 中间层（侧载安全路径）
            if let file = fileURLs.first {
                AuditLog.shared.log("share.quicklook", detail: file.lastPathComponent)
                Self.isPresenting = true
                ShareCenter.shared.presentQuickLook(url: file, delay: 0.3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    Self.isPresenting = false
                }
                completion?(true, nil)
                return
            }

            // 纯文字/链接 → 剪贴板兜底 + 提示
            if !texts.isEmpty {
                ShareCenter.shared.fallbackClipboard(texts.joined(separator: "\n"))
                AuditLog.shared.log("share.fallback_clipboard", detail: "texts=\(texts.count)")
                completion?(false, NSError(domain: "SharePresenter", code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: "侧载环境分享面板不可用，文字已复制到剪贴板"]))
                return
            }

            if otherCount > 0 {
                AuditLog.shared.log("share.other_items", detail: "count=\(otherCount)")
                completion?(false, NSError(domain: "SharePresenter", code: -5,
                                           userInfo: [NSLocalizedDescriptionKey: "无法分享该内容"]))
                return
            }

            AuditLog.shared.log("share.all_invalid", detail: "items=\(items.count)")
            completion?(false, NSError(domain: "SharePresenter", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: "分享内容无效"]))
        }
    }
}

// MARK: - SwiftUI 系统分享入口（v4.3.44 收紧到 iOS 16.4）
//
// 版本门槛对齐 TrollFools 的 `if #available(iOS 16.4, *)`：
// 实测 iOS 16.0~16.3 的 ShareLink 在侧载环境仍可能触发 MobileIcons/CoreImage 崩溃；
// 16.4 以下一律走 QuickLook 中间层（ShareCenter），确保任何 iOS 版本都不闪退。
extension SharePresenter {

    /// 上下文菜单里的"分享"项（文件 URL）
    @ViewBuilder
    static func menuShare(url: URL, label: String = "分享",
                          systemImage: String = "square.and.arrow.up") -> some View {
        if #available(iOS 16.4, *) {
            ShareLink(item: url) { Label(label, systemImage: systemImage) }
        } else {
            Button { ShareCenter.shared.presentQuickLook(url: url, delay: 0.35) } label: {
                Label(label, systemImage: systemImage)
            }
        }
    }

    /// 上下文菜单里的"分享"项（文本）
    @ViewBuilder
    static func menuShare(text: String, label: String = "分享",
                          systemImage: String = "square.and.arrow.up") -> some View {
        if #available(iOS 16.4, *) {
            ShareLink(item: text) { Label(label, systemImage: systemImage) }
        } else {
            Button { ShareCenter.shared.fallbackClipboard(text) } label: {
                Label(label, systemImage: systemImage)
            }
        }
    }

    /// 工具栏里的"分享"图标按钮（文本）
    @ViewBuilder
    static func toolbarShare(text: String) -> some View {
        if #available(iOS 16.4, *) {
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
            }
        } else {
            Button { ShareCenter.shared.fallbackClipboard(text) } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
            }
        }
    }

    /// 工具栏里的"分享"图标按钮（文件 URL）
    @ViewBuilder
    static func toolbarShare(url: URL) -> some View {
        if #available(iOS 16.4, *) {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
            }
        } else {
            Button { ShareCenter.shared.presentQuickLook(url: url, delay: 0.2) } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
            }
        }
    }
}
