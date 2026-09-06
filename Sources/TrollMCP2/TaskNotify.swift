import Foundation
import UserNotifications
import UIKit

// v2.9.82：任务完成通知 + 后台执行延长
// - iOS 无越狱下 TrollStore App 无法真正后台常驻（受系统后台机制限制），
//   这里做两层补偿：beginBackgroundTask 尽量延长切后台后的执行时间；
//   请求结束（成功/失败/中断）时若 App 在后台，发本地通知提醒用户。
final class TaskNotify {
    static let shared = TaskNotify()
    private let defaults = UserDefaults.standard
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var enabled: Bool {
        get { defaults.object(forKey: "taskNotify.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "taskNotify.enabled") }
    }

    /// 首次请求通知权限（App 启动 / 首次发送消息时调用）
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 仅在 App 处于后台/挂起时发本地通知（前台不打扰）
    func notifyIfBackground(title: String, body: String) {
        guard enabled else { return }
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    /// 开始后台任务（切后台后尽量延长执行，系统上限约 30 秒）
    func beginBackground() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    func endBackground() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
}
