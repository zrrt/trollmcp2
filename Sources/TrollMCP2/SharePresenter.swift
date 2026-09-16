import UIKit

/// v2.9.169：统一安全分享器——全部分享点共用，修复 iOS 16 分享闪退根因。
///
/// 旧实现（ModelsView/UpdateManager 等）直接 `rootVC.present(UIActivityViewController)`
/// 在两种场景必崩：
/// 1) contextMenu（长按消息/文件）点"分享"时菜单还在 dismiss 动画中，立即 present
///    抛 "Attempt to present ... whose view is not in the window hierarchy"；
/// 2) 当前已有 presented sheet（如设置子页）时再 present，抛 "already presenting"。
///
/// 统一策略：主线程 → 找 keyWindow 最顶层 presented（跳过正在 dismiss 的）→
/// 若顶层正 dismiss / 无 window 则延时 0.4s 重试 → iPad popover 适配 → 顶层无
/// presented 才 present。
enum SharePresenter {
    static func present(
        _ items: [Any],
        excluded: [UIActivity.ActivityType] = [],
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if !excluded.isEmpty {
                vc.excludedActivityTypes = excluded
            }
            if let completion {
                vc.completionWithItemsHandler = { _, completed, _, error in
                    completion(completed, error)
                }
            }
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: { $0.isKeyWindow }),
                  let root = window.rootViewController else {
                return
            }

            // 找最顶层 presentedViewController（跳过正在 dismiss 的）
            var top = root
            while let p = top.presentedViewController, !p.isBeingDismissed {
                top = p
            }

            // 顶层正在 dismiss（contextMenu 收起动画中）或视图已脱离窗口 → 延后重试
            if top.isBeingDismissed || top.view.window == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    presentFrom(top: root, vc: vc, rootView: window)
                }
                return
            }
            presentFrom(top: top, vc: vc, rootView: window)
        }
    }

    private static func presentFrom(top: UIViewController, vc: UIActivityViewController, rootView: UIView) {
        // iPad 必须指定 popover 锚点
        if let popover = vc.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        // 二次防御：若期间又弹出了别的控制器则放弃，避免 "already presenting" 崩溃
        guard top.presentedViewController == nil else { return }
        top.present(vc, animated: true)
    }
}
