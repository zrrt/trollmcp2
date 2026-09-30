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
/// - iOS 16.4 以下：不手写分享面板，改为先弹 QuickLook 预览（.quickLookPreview），
///   用户在预览页点系统自带的分享按钮，由系统在自己安全上下文里弹出分享面板——
///   绕过手写 UIActivityViewController 枚举分享扩展的崩溃路径。
///
/// ShareCenter 作为 RootView 挂载的 @Published 状态，任何命令式上下文（后台线程、Alert 回调、
/// 工具链）都能通过 `ShareCenter.shared.quickLookURL = url` 安全触发 QuickLook 中间层。
final class ShareCenter: ObservableObject {
    static let shared = ShareCenter()

    /// QuickLook 预览中转：非空时 RootView 上的 .quickLookPreview 会弹出预览，
    /// 用户在预览页通过系统分享按钮完成分享（不崩）。
    @Published var quickLookURL: URL?

    private init() {}

    /// 触发 QuickLook 中间层（文件分享兜底，任意线程安全）
    func presentQuickLook(url: URL) {
        DispatchQueue.main.async {
            self.quickLookURL = url
        }
    }
}
