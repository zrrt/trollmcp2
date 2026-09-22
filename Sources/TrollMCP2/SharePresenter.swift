import UIKit

/// v3.1.23：统一安全分享器——全部分享点共用，修复侧载环境分享闪退。
///
/// 旧实现用 UIActivityViewController，在侧载环境下枚举系统分享图标时会系统级 Segfault。
/// 改为 UIDocumentInteractionController（OpenInMenu）——只显示"用其他 App 打开"的菜单，
/// 不枚举所有分享图标，侧载环境下稳定。
///
/// 支持：
/// - 文件 URL：用 OpenInMenu 打开，可分享到微信/巨魔/文件管理等
/// - 文字：复制到剪贴板 + 提示用户
enum SharePresenter {
    static func present(
        _ items: [Any],
        excluded: [UIActivity.ActivityType] = [],
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            // 过滤出文件 URL
            var fileURLs: [URL] = []
            var texts: [String] = []
            
            for item in items {
                if let url = item as? URL, url.isFileURL {
                    if FileManager.default.fileExists(atPath: url.path) {
                        fileURLs.append(url)
                    } else {
                        AuditLog.shared.log("share.invalid_url", detail: url.path)
                    }
                } else if let str = item as? String {
                    texts.append(str)
                }
            }
            
            // 如果有文字，先复制到剪贴板
            if !texts.isEmpty {
                let fullText = texts.joined(separator: "\n")
                UIPasteboard.general.string = fullText
                AuditLog.shared.log("share.text_copied", detail: "chars=\(fullText.count)")
            }
            
            // 如果有文件，用 UIDocumentInteractionController 打开
            if !fileURLs.isEmpty {
                guard let window = Self.topWindow() else {
                    AuditLog.shared.log("share.present_no_window", detail: "items=\(items.count)")
                    completion?(false, NSError(domain: "SharePresenter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取窗口"]))
                    return
                }
                guard let root = window.rootViewController else {
                    AuditLog.shared.log("share.present_no_root", detail: "")
                    completion?(false, NSError(domain: "SharePresenter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取根控制器"]))
                    return
                }
                
                // 延时 0.45s 等转场动画结束
                let top = root
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    // 只支持单文件分享（OpenInMenu 一次只能打开一个文件）
                    if let firstURL = fileURLs.first {
                        let controller = UIDocumentInteractionController(url: firstURL)
                        controller.presentOpenInMenu(
                            from: CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0),
                            in: top.view,
                            animated: true
                        )
                        AuditLog.shared.log("share.present", detail: "openIn: \(firstURL.lastPathComponent)")
                        completion?(true, nil)
                    }
                }
            } else if !texts.isEmpty {
                // 只有文字，已经复制到剪贴板了
                AuditLog.shared.log("share.only_text", detail: "copied to clipboard")
                completion?(true, nil)
            } else {
                AuditLog.shared.log("share.all_invalid", detail: "items=\(items.count)")
                completion?(false, NSError(domain: "SharePresenter", code: -1, userInfo: [NSLocalizedDescriptionKey: "分享内容无效"]))
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
}
