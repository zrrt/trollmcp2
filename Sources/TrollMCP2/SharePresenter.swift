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
    /// v4.3.43：防重入锁——同一时刻只允许一个分享页在弹。
    /// 侧载环境下快速连点分享/多入口同时触发会并发 present 两个
    /// UIActivityViewController → "presenting while already presenting" 闪退。
    /// 锁持有期间的新调用直接忽略（记审计日志），避免堆叠。
    private static var isPresenting = false

    static func present(
        _ items: [Any],
        excluded: [UIActivity.ActivityType] = [],
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            // 防重入：分享页已弹出时忽略新请求（快速连点 / 多入口同时触发）
            if Self.isPresenting {
                AuditLog.shared.log("share.busy", detail: "items=\(items.count)")
                completion?(false, NSError(domain: "SharePresenter", code: -3,
                                           userInfo: [NSLocalizedDescriptionKey: "分享页已打开"]))
                return
            }

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

            // v4.3.43：不再直接 present——先等转场结束（最多重试 3 次），
            // 拿不到宿主或转场超时才走降级路径。
            Self.presentAfterTransition(
                items: activityItems,
                fileURLs: fileURLs,
                excluded: excluded,
                retryForHost: true,
                completion: completion
            )
        }
    }

    // MARK: - 转场等待 + 有限重试

    /// 等待宿主转场结束再 present；若仍处于转场中则最多重试 3 次（每次 0.25s）。
    /// present 前额外检查宿主状态（isBeingPresented/isBeingDismissed/已释放），
    /// 不满足则继续等待，避免 "Attempt to present ... while a presentation is in progress" 崩溃。
    /// - Parameters:
    ///   - fallbackHost: 上一轮捕获的宿主（转场期间可能变化）
    ///   - retryForHost: 为 true 时，若拿不到顶层 VC 则先重试查找，最终仍失败再降级
    private static func presentAfterTransition(
        items: [Any],
        fileURLs: [URL],
        excluded: [UIActivity.ActivityType],
        fallbackHost: UIViewController? = nil,
        attempts: Int = 0,
        retryForHost: Bool = false,
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !Self.isPresenting else { return }

            // 延迟后重新取顶层（转场可能已变化）；取不到就退回上一轮捕获的宿主
            let top = Self.topViewController() ?? fallbackHost

            // 拿不到宿主：若允许则重试查找，超限后走降级路径
            guard let top = top else {
                if retryForHost, attempts < 3 {
                    Self.presentAfterTransition(
                        items: items, fileURLs: fileURLs, excluded: excluded,
                        fallbackHost: nil, attempts: attempts + 1,
                        retryForHost: true, completion: completion)
                    return
                }
                AuditLog.shared.log("share.no_host_timeout", detail: "attempts=\(attempts)")
                Self.fallback(fileURLs: fileURLs, items: items, completion: completion)
                return
            }

            let transitioning = top.isBeingPresented || top.isBeingDismissed
            let detached = top.view.window == nil

            // 宿主正在转场或已被移除 → 等下一轮；最多 3 次
            if transitioning || detached {
                if attempts < 3 {
                    Self.presentAfterTransition(
                        items: items, fileURLs: fileURLs, excluded: excluded,
                        fallbackHost: top, attempts: attempts + 1,
                        retryForHost: retryForHost, completion: completion)
                    return
                }
                AuditLog.shared.log("share.transition_timeout", detail: "attempts=\(attempts)")
                completion?(false, NSError(domain: "SharePresenter", code: -4,
                                           userInfo: [NSLocalizedDescriptionKey: "界面转场未完成，请稍后再试"]))
                return
            }

            Self.isPresenting = true
            let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
            vc.excludedActivityTypes = excluded.isEmpty ? nil : excluded
            vc.completionWithItemsHandler = { _, completed, _, error in
                Self.isPresenting = false
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

    // MARK: - 降级路径

    /// 降级路径：文件 → OpenInMenu；纯文字 → 剪贴板（拿不到宿主 / 超时时兜底）。
    private static func fallback(fileURLs: [URL], items: [Any], completion: ((Bool, Error?) -> Void)?) {
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
            let texts = items.compactMap { $0 as? String }
            if !texts.isEmpty {
                UIPasteboard.general.string = texts.joined(separator: "\n")
            }
            AuditLog.shared.log("share.fallback_clipboard", detail: "texts=\(texts.count)")
            completion?(false, NSError(domain: "SharePresenter", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "无法弹出分享页，文字内容已复制到剪贴板"]))
        }
    }

    // MARK: - 顶层控制器查找

    /// 取 keyWindow 最顶层可 present 的控制器；沿 presented 链上溯，
    /// 遇到 UIAlertController 停在其 presenting 控制器（alert 上不能再 present）；
    /// 遇到正在转场的控制器返回 nil（交由调用方等待重试，避免在转场中 present 崩溃）。
    private static func topViewController() -> UIViewController? {
        guard let window = Self.topWindow(), var root = window.rootViewController else { return nil }
        // 根控制器自身处于转场中 → 不稳定，返回 nil 触发等待
        if root.isBeingPresented || root.isBeingDismissed { return nil }
        while let presented = root.presentedViewController {
            // alert 上不能再 present，停在其 presenting 控制器
            if presented is UIAlertController { break }
            // 正在转场中的控制器：整个 presented 链不稳定，返回 nil 让调用方等待重试
            if presented.isBeingPresented || presented.isBeingDismissed { return nil }
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
