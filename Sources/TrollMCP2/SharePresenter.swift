import UIKit

/// v2.9.170：统一安全分享器——全部分享点共用，修复 iOS 16 分享闪退/无反应。
///
/// 旧实现（ModelsView/UpdateManager 等）直接 `rootVC.present(UIActivityViewController)`
/// 在两种场景必崩：
/// 1) contextMenu（长按消息/文件）点"分享"时菜单还在 dismiss 动画中，立即 present
///    抛 "Attempt to present ... whose view is not in the window hierarchy"；
/// 2) 当前已有 presented sheet（如设置子页）时再 present，抛 "already presenting"。
///
/// v2.9.170 增强（用户反馈 169 仍"失败"）：
/// 1) 窗口获取多级兜底：connectedScenes 的 keyWindow → 该 scene 首个 window →
///    UIApplication.shared.windows.first（iOS 16 废弃但可用），避免 guard 静默 return
///    导致"点了没反应"；
/// 2) 失败不再静默：拿不到窗口/根控制器时写 AuditLog（share.present_no_window /
///    share.present_no_root），用户可在工作区日志里查根因；
/// 3) 延时重试也做同样的多级兜底。
enum SharePresenter {
    static func present(
        _ items: [Any],
        excluded: [UIActivity.ActivityType] = [],
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            // v2.9.255: 分享前校验 items——文件 URL 不存在/不可读时直接返回明确错误，
            // 避免 UIActivityViewController 收到无效文件后白屏/无反应（用户多轮反馈"分享打开半天空白"）
            var validItems: [Any] = []
            var invalidCount = 0
            for item in items {
                if let url = item as? URL {
                    if url.isFileURL {
                        if FileManager.default.fileExists(atPath: url.path) {
                            validItems.append(item)
                        } else {
                            invalidCount += 1
                            AuditLog.shared.log("share.invalid_url", detail: url.path)
                        }
                    } else {
                        validItems.append(item)
                    }
                } else {
                    validItems.append(item)
                }
            }
            guard !validItems.isEmpty else {
                AuditLog.shared.log("share.all_invalid", detail: "items=\(items.count)")
                completion?(false, NSError(
                    domain: "SharePresenter",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "分享内容无效（文件不存在或不可读）"]
                ))
                return
            }
            let vc = UIActivityViewController(activityItems: validItems, applicationActivities: nil)
            if !excluded.isEmpty {
                vc.excludedActivityTypes = excluded
            }
            if let completion = completion {
                vc.completionWithItemsHandler = { _, completed, _, error in
                    completion(completed, error)
                }
            }
            guard let window = Self.topWindow() else {
                AuditLog.shared.log("share.present_no_window", detail: "items=\(items.count)")
                return
            }
            guard let root = window.rootViewController else {
                AuditLog.shared.log("share.present_no_root", detail: "")
                return
            }

            // v2.9.172：无条件延时 0.45s 再弹——iOS 16 从 contextMenu / sheet 转场
            // 动画未结束时弹出 UIActivityViewController 是已知白屏/崩溃源。
            // contextMenu 不是 presentedViewController，旧 isBeingDismissed 检测不到，
            // 所以改为一律等转场动画完全结束，牺牲 0.45s 换取稳定。
            let top = root
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                presentFrom(top: top, vc: vc, window: window)
            }
        }
    }

    /// 多级窗口获取：keyWindow → scene 首个 window → 旧 API windows.first
    private static func topWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first,
           let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return win
        }
        return UIApplication.shared.windows.first
    }

    private static func presentFrom(top: UIViewController, vc: UIActivityViewController, window: UIWindow) {
        // iPad 必须指定 popover 锚点
        if let popover = vc.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        // v3.0.82: 先 dismiss 现有的 presentedViewController，再 present——避免 already presenting 崩溃
        if let existing = top.presentedViewController {
            existing.dismiss(animated: false) {
                top.present(vc, animated: true)
                AuditLog.shared.log("share.present", detail: "ok (after dismiss)")
            }
        } else {
            top.present(vc, animated: true)
            AuditLog.shared.log("share.present", detail: "ok")
        }
    }
}
