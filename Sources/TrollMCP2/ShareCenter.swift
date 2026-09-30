import SwiftUI
import UIKit

/// v4.3.44：分享中转站——TrollStore 侧载环境的"分享面板闪退"根治方案。
///
/// 背景（崩溃栈实证）：TrollMCP2 在侧载环境直接手写 present UIActivityViewController 时，
/// ShareSheet 枚举分享扩展并生成目标图标（MobileIcons/LICreateIconForImages → CoreImage）会
/// 触发系统级 SIGSEGV（Segmentation fault: 11），App 进程被系统杀死。
///
/// 解法（100% 照抄 TrollStore 生态 App **TrollFools**，其在本用户设备实测分享不崩）：
/// - iOS 16.4+：SwiftUI 原生 `ShareLink`；
/// - iOS 16.4 以下：**SwiftUI 原生 `.quickLookPreview($url)`**，挂在分享触发视图自身
///   （TrollFools：EjectListView `@State var quickLookExport: URL?` + `.quickLookPreview($quickLookExport)`，
///   PlugInCell contextMenu 按钮 `quickLookExport = plugIn.url`）。QLPreviewController 在主窗口
///   正常呈现上下文弹出，预览页导航栏自带系统分享按钮，由系统自身上下文弹分享面板——不崩。
///
/// 呈现方式迭代记录（均被真机证伪）：
/// 1. `.quickLookPreview` 挂在 RootView（层级过深/被 fullScreenCover 干扰）→ contextMenu 触发被吞；
/// 2. 显式 fullScreenCover 呈现 → SwiftUI 呈现队列在 contextMenu dismiss 期间仍不可靠；
/// 3. 独立 UIWindow(alert+1) → 预览能弹，但 QLPreviewController 分享按钮弹分享面板时
///    在异常呈现上下文触发 MobileIcons/CoreImage SIGSEGV（用户实测闪退）。
/// → 最终：照抄 TrollFools，`.quickLookPreview` 挂分享触发视图自身（主窗口正常上下文）。
final class ShareCenter: ObservableObject {
    static let shared = ShareCenter()

    /// 剪贴板/写入提示文案（nil = 无提示）
    @Published var clipboardNotice: String?

    /// 命令式调用（非 View 上下文：UpdateManager/后台）的 QuickLook 兜底 URL。
    /// RootView 上挂 `.quickLookPreview($shareCenter.quickLookURL)` 承接。
    @Published var quickLookURL: URL?

    private init() {}

    /// 命令式分享（非 View 上下文）兜底：设置全局 QuickLook URL，
    /// 由 RootView 的 .quickLookPreview 呈现（非 contextMenu 触发，呈现不被吞）。
    func presentQuickLook(url: URL) {
        DispatchQueue.main.async {
            self.quickLookURL = url
            AuditLog.shared.log("share.quicklook_center", detail: url.lastPathComponent)
        }
    }

    /// 关闭命令式 QuickLook（RootView onDismiss 调用）
    func dismissQuickLook() {
        DispatchQueue.main.async {
            self.quickLookURL = nil
        }
    }

    // MARK: - 文字 → 临时 txt

    /// 把文字写入临时 txt 文件，返回 URL；失败返回 nil。
    /// 用于 SwiftUI 入口（menuShare/toolbarShare）低版本分支：写 txt 后设置视图 @State
    /// quickLookExport，走 .quickLookPreview（文字也能进系统分享面板，不再降级复制）。
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

    /// 命令式文字分享（非 View 上下文）：写 txt → 全局 QuickLook；写失败 → 剪贴板兜底
    func presentText(_ text: String) {
        if let url = Self.writeTextToTemp(text) {
            presentQuickLook(url: url)
            AuditLog.shared.log("share.text_to_file", detail: url.lastPathComponent)
        } else {
            fallbackClipboard(text)
            AuditLog.shared.log("share.text_fallback_clipboard", detail: "write_failed")
        }
    }

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
}
