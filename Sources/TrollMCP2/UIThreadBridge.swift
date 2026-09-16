import Foundation
import UIKit

/// v2.9.147：UIKit 线程安全桥——AI 工具在后台线程执行，
/// 直接访问 UIPasteboard / UIApplication.open 会触发 SIGSEGV 段错误闪退
/// （iOS 强制 UIKit 主线程，后台访问 = 崩溃，用户反复闪退的根因之一）。
/// 所有工具内 UIKit 访问一律走这里。
enum UIThreadBridge {

    /// 写剪贴板（任意线程安全）
    static func paste(_ text: String) {
        if Thread.isMainThread {
            UIPasteboard.general.string = text
        } else {
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        }
    }

    /// 读剪贴板（任意线程安全，后台线程同步等待主线程结果）
    static func readClipboard() -> String {
        if Thread.isMainThread {
            return UIPasteboard.general.string ?? ""
        }
        var result = ""
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            result = UIPasteboard.general.string ?? ""
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
        return result
    }

    /// 打开 URL（任意线程安全）
    /// - 主线程调用：fire-and-forget（避免 sem.wait 阻塞主线程导致 completion 永不回调死锁）
    /// - 后台线程调用：切主线程执行并同步等待结果
    static func openURL(_ url: URL, timeout: Double = 5) -> Bool {
        if Thread.isMainThread {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return true
        }
        var opened = false
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                opened = ok
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return opened
    }
}
