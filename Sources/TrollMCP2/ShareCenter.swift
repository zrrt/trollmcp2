import SwiftUI
import UIKit

/// v4.3.44：分享中转站——TrollStore 侧载环境的"分享面板闪退"根治方案。
///
/// 背景（崩溃栈实证）：TrollMCP2 在侧载环境直接手写 present UIActivityViewController 时，
/// ShareSheet 枚举分享扩展并生成目标图标（MobileIcons/LICreateIconForImages → CoreImage）会
/// 触发系统级 SIGSEGV（Segmentation fault: 11），App 进程被系统杀死——无论怎么调整 present
/// 时机/防重入都无法规避，因为崩溃发生在系统框架内部。
///
/// 解法（照抄 TrollStore 生态 App TrollFools 的稳定做法）：
/// - iOS 16.4+：SwiftUI 原生 ShareLink，由系统在正确 window scene/宿主上下文呈现分享面板；
/// - iOS 16.4 以下：不手写分享面板，改为先弹 QuickLook 预览，用户在预览页点系统自带的
///   分享按钮，由系统在自己安全上下文里弹出分享面板——绕过手写 UIActivityViewController
///   枚举分享扩展的崩溃路径。
///
/// v4.3.44 呈现方式：第一版用 SwiftUI `.quickLookPreview($url)` 隐式绑定，实测在 contextMenu
/// 等入口触发时预览呈现会被菜单 dismiss 动画吞掉（表现为"点击分享没反应"）。本版改为
/// **显式 fullScreenCover**：`isQuickLookPresented` 驱动 RootView 的 fullScreenCover，
/// 内容为带导航栏的 QLPreviewController（导航栏自带系统分享按钮），触发可靠性远高于隐式绑定。
final class ShareCenter: ObservableObject {
    static let shared = ShareCenter()

    /// 待预览的文件 URL（分享中间层的"文件"，一次一个）
    @Published var quickLookURL: URL?

    /// 是否正在展示 QuickLook 预览（RootView fullScreenCover 绑定）
    @Published var isQuickLookPresented = false

    /// 纯文字降级复制到剪贴板后的提示文案（nil = 无提示）
    @Published var clipboardNotice: String?

    private init() {}

    /// 触发 QuickLook 中间层（文件分享，任意线程安全）。
    /// - Parameter delay: 从 contextMenu 等正在 dismiss 的 UI 触发时，延迟到 dismiss
    ///   完成后再呈现，避免呈现动画被系统吞掉（"点击分享没反应"）。
    func presentQuickLook(url: URL, delay: TimeInterval = 0) {
        DispatchQueue.main.async {
            self.quickLookURL = url
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.isQuickLookPresented = true
                }
            } else {
                self.isQuickLookPresented = true
            }
        }
    }

    /// 关闭 QuickLook 预览（fullScreenCover dismiss 时调用）
    func dismissQuickLook() {
        DispatchQueue.main.async {
            self.isQuickLookPresented = false
            self.quickLookURL = nil
        }
    }

    /// 纯文字/链接降级：复制到剪贴板并提示
    func fallbackClipboard(_ text: String) {
        UIPasteboard.general.string = text
        DispatchQueue.main.async {
            self.clipboardNotice = "已复制到剪贴板（侧载环境分享面板不可用）"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.clipboardNotice = nil
            }
        }
    }
}
