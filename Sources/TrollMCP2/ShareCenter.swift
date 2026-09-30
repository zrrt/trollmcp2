import SwiftUI
import UIKit
import QuickLook

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
/// v4.3.44 呈现方式迭代：
/// 1. `.quickLookPreview($url)` 隐式绑定 → contextMenu 触发时被 dismiss 动画吞掉（没反应）；
/// 2. fullScreenCover 显式呈现 → SwiftUI 呈现队列在 contextMenu dismiss 期间仍不可靠（没反应）；
/// 3. **独立 UIWindow 直接呈现（当前版）**——在 UIKit 层面创建一个 windowLevel=alert+1 的
///    独立窗口，rootViewController = UINavigationController(QLPreviewController)，完全不经过
///    SwiftUI 呈现队列，任何入口（contextMenu/工具栏/Alert 回调/后台线程）触发都 100% 弹出。
///    预览页导航栏自带系统分享按钮，用户在预览页点分享 → 系统自身上下文弹面板（不崩）。
final class ShareCenter: ObservableObject {
    static let shared = ShareCenter()

    /// 剪贴板/写入提示文案（nil = 无提示）
    @Published var clipboardNotice: String?

    /// 独立 QuickLook 窗口（强持有，防止释放）
    private var quickLookWindow: UIWindow?
    private let dataSource = SharePreviewDataSource()

    private init() {}

    // MARK: - 文件分享：QuickLook 中间层（核心）

    /// 呈现指定文件的 QuickLook 预览（分享中间层）。
    /// 任意线程安全；任何 UI 状态下（contextMenu/Alert/后台）都能可靠弹出。
    func presentQuickLook(url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 文件必须存在；不存在则提示（不静默失败）
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.showNotice("文件不存在，无法分享")
                return
            }
            // 取前台活跃 scene（无活跃则取第一个）
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
                self.showNotice("无法获取窗口，请重试")
                return
            }

            // 独立窗口，windowLevel 高于主窗口，确保盖在所有 UI 之上
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .systemBackground

            // QLPreviewController 导航栏自带系统分享按钮（系统上下文弹面板，规避崩溃）
            self.dataSource.currentURL = url
            let ql = QLPreviewController()
            ql.dataSource = self.dataSource
            ql.delegate = self.dataSource
            ql.navigationItem.title = url.lastPathComponent

            let nav = UINavigationController(rootViewController: ql)
            nav.navigationBar.topItem?.leftBarButtonItem = UIBarButtonItem(
                title: "完成", style: .done,
                target: self, action: #selector(self.dismissQuickLookAction))
            window.rootViewController = nav
            window.makeKeyAndVisible()
            self.quickLookWindow = window

            AuditLog.shared.log("share.quicklook_window", detail: url.lastPathComponent)
        }
    }

    // MARK: - 文字分享：写入临时 txt → QuickLook（让文字也能进系统分享面板）

    /// 把文字写入临时 txt 文件再走 QuickLook 中间层。
    /// 这样聊天内容/深链等文字也能进系统分享面板（微信/隔空投送/存储到文件），
    /// 而不是只能降级复制。文件名带时间戳，多次分享不冲突。
    func presentText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showNotice("没有可分享的内容")
            return
        }
        // 文件名：前 12 字符（去非法字符）+ 时间戳
        let prefix = String(trimmed.prefix(12))
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = "分享_\(prefix.isEmpty ? "文本" : prefix)_\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try trimmed.data(using: .utf8)?.write(to: url)
            presentQuickLook(url: url)
            AuditLog.shared.log("share.text_to_file", detail: name)
        } catch {
            // 写文件失败 → 复制兜底
            UIPasteboard.general.string = trimmed
            showNotice("已复制到剪贴板")
            AuditLog.shared.log("share.text_fallback_clipboard", detail: error.localizedDescription)
        }
    }

    // MARK: - 降级与提示

    /// 纯文字/链接复制兜底（写文件失败或调用方明确要求复制时）
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

    // MARK: - 关闭

    @objc func dismissQuickLookAction() {
        DispatchQueue.main.async {
            self.quickLookWindow?.isHidden = true
            self.quickLookWindow = nil
        }
    }
}

// MARK: - QLPreviewController 数据源/代理

/// QLPreviewController 的数据源与代理：持有一个 URL，导航栏分享按钮由系统提供。
private final class SharePreviewDataSource: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    var currentURL: URL?

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        (currentURL != nil && FileManager.default.fileExists(atPath: currentURL!.path)) ? 1 : 0
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        currentURL! as NSURL
    }
}
