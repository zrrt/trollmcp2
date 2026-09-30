import SwiftUI

/// v4.3.41：统一分享器——优先弹出 iOS 系统完整分享页 UIActivityViewController
/// （微信/短信/隔空投送/存储到文件/用 TrollStore 打开/复制 等全部活动项）。
///
/// TrollStore(巨魔)侧载环境同样可用，关键三点：
/// 1. 在 keyWindow 最顶层、且转场动画结束后再 present（从 sheet/弹窗里触发时尤其重要）；
/// 2. 沿 presentedViewController 链找到最顶层控制器，并跳过 UIAlertController（alert 上不能再 present）；
/// 3. iPad 必须配置 popoverPresentationController 的 sourceView/sourceRect，否则崩溃。
///
/// 兜底：拿不到窗口/控制器时，文件降级 UIDocumentInteractionController(OpenInMenu)，
/// 纯文字降级复制到剪贴板。
enum SharePresenter {
    static func present(
        _ items: [Any],
        excluded: [UIActivity.ActivityType] = [],
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            // 收集有效分享项：文件 URL 需真实存在；http(s) 链接、字符串、其他对象原样传入
            var activityItems: [Any] = []
            var fileURLs: [URL] = []

            for item in items {
                if let url = item as? URL, url.isFileURL {
                    if FileManager.default.fileExists(atPath: url.path) {
                        activityItems.append(url)
                        fileURLs.append(url)
                    } else {
                        AuditLog.shared.log("share.invalid_url", detail: url.path)
                    }
                } else {
                    activityItems.append(item)
                }
            }

            guard !activityItems.isEmpty else {
                AuditLog.shared.log("share.all_invalid", detail: "items=\(items.count)")
                completion?(false, NSError(domain: "SharePresenter", code: -2,
                                           userInfo: [NSLocalizedDescriptionKey: "分享内容无效"]))
                return
            }

            // 降级路径：文件 → OpenInMenu；纯文字 → 剪贴板
            func fallback() {
                if let file = fileURLs.first, let top = Self.topViewController() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let dc = UIDocumentInteractionController(url: file)
                        dc.presentOpenInMenu(
                            from: CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0),
                            in: top.view, animated: true)
                        AuditLog.shared.log("share.fallback_openin", detail: file.lastPathComponent)
                        completion?(true, nil)
                    }
                } else {
                    let texts = activityItems.compactMap { $0 as? String }
                    if !texts.isEmpty {
                        UIPasteboard.general.string = texts.joined(separator: "\n")
                    }
                    AuditLog.shared.log("share.fallback_clipboard", detail: "texts=\(texts.count)")
                    completion?(false, NSError(domain: "SharePresenter", code: -1,
                                               userInfo: [NSLocalizedDescriptionKey: "无法弹出分享页，文字内容已复制到剪贴板"]))
                }
            }

            guard let host = Self.topViewController() else {
                AuditLog.shared.log("share.present_no_vc", detail: "items=\(items.count)")
                fallback()
                return
            }

            // 延时等转场动画结束（confirmationDialog/sheet dismiss 后再 present）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                // 延迟后重新取顶层（转场可能已变化）；取不到就退回转场前捕获的宿主
                let top = Self.topViewController() ?? host

                let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
                vc.excludedActivityTypes = excluded.isEmpty ? nil : excluded
                vc.completionWithItemsHandler = { _, completed, _, error in
                    AuditLog.shared.log("share.completed", detail: "ok=\(completed)")
                    completion?(completed, error)
                }
                // iPad：必须指定弹窗锚点，否则崩溃；iPhone 上该配置被忽略
                if let pop = vc.popoverPresentationController {
                    pop.sourceView = top.view
                    pop.sourceRect = CGRect(x: top.view.bounds.midX,
                                            y: top.view.bounds.maxY - 80,
                                            width: 0, height: 0)
                    pop.permittedArrowDirections = []
                }
                top.present(vc, animated: true) {
                    AuditLog.shared.log("share.present",
                                        detail: fileURLs.first?.lastPathComponent ?? "text/link")
                }
            }
        }
    }

    /// 取 keyWindow 最顶层可 present 的控制器；沿 presented 链上溯，
    /// 遇到 UIAlertController 停在其 presenting 控制器（alert 上不能再 present）。
    private static func topViewController() -> UIViewController? {
        guard let window = Self.topWindow(), var root = window.rootViewController else { return nil }
        while let presented = root.presentedViewController {
            if presented is UIAlertController { break }
            // 正在转场中的控制器不作为宿主
            if presented.isBeingPresented || presented.isBeingDismissed { break }
            root = presented
        }
        return root
    }

    /// 多 scene 下取前台活跃场景的 keyWindow
    private static func topWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let win = active?.windows.first(where: { $0.isKeyWindow }) ?? active?.windows.first {
            return win
        }
        return UIApplication.shared.windows.first
    }
}

// MARK: - SwiftUI 系统分享入口（v4.3.42）
//
// 关键：iOS16+ 用 SwiftUI 原生 ShareLink。它由 SwiftUI/系统在正确的 window scene 与
// 宿主控制器上下文里呈现 UIActivityViewController，不经过手写的 keyWindow/顶层VC 查找——
// 这是 TrollStore 生态 App（如 TrollFools）验证过的稳定做法，规避侧载环境下手写 present
// 枚举分享扩展时的闪退。iOS15 无 ShareLink，兜底走命令式 SharePresenter。
extension SharePresenter {

    /// 上下文菜单里的"分享"项（文件 URL）
    @ViewBuilder
    static func menuShare(url: URL, label: String = "分享",
                          systemImage: String = "square.and.arrow.up") -> some View {
        if #available(iOS 16, *) {
            ShareLink(item: url) { Label(label, systemImage: systemImage) }
        } else {
            Button { present([url]) } label: { Label(label, systemImage: systemImage) }
        }
    }

    /// 上下文菜单里的"分享"项（文本）
    @ViewBuilder
    static func menuShare(text: String, label: String = "分享",
                          systemImage: String = "square.and.arrow.up") -> some View {
        if #available(iOS 16, *) {
            ShareLink(item: text) { Label(label, systemImage: systemImage) }
        } else {
            Button { present([text]) } label: { Label(label, systemImage: systemImage) }
        }
    }

    /// 工具栏里的"分享"图标按钮（文本）
    @ViewBuilder
    static func toolbarShare(text: String) -> some View {
        if #available(iOS 16, *) {
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
            }
        } else {
            Button { present([text]) } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
            }
        }
    }

    /// 工具栏里的"分享"图标按钮（文件 URL）
    @ViewBuilder
    static func toolbarShare(url: URL) -> some View {
        if #available(iOS 16, *) {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
            }
        } else {
            Button { present([url]) } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
            }
        }
    }
}
