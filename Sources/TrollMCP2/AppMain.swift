import UIKit
import SwiftUI

@main
struct TrollMCP2App {
    static func main() {
        UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(AppDelegate.self)
        )
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // v2.9.368：全局 UITextView 零内边距——TextEditor 默认有 8pt 上下内边距，
        // 导致输入框高度过大；全局清零后 TextEditor 高度紧贴文字。
        UITextView.appearance().textContainerInset = .zero

        CrashCatcher.install()  // v2.9.145c：最先注册崩溃捕获，闪退自动落盘 crash/ 可查
        Workspace.ensure()
        // v4.3.63 骨架测试版：禁用全部启动初始化（DeviceProbe/Location/AppLifecycle/
        // UpdateManager/DeviceReporter/RemoteAgent/KeepAlive/ConfigMigration/ToolRegistry），
        // 只保留最小 UI + 分享入口——二分定位"运行时初始化污染 vs App 静态特性"。
        // 若骨架版分享正常 → 初始化污染 → 逐个加回定位；若仍崩 → 静态特性（构建/签名/plist）。

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIHostingController(rootView: RootView())
        window?.makeKeyAndVisible()

        return true
    }

    // v2.9.10：进后台时申请后台任务，让正在进行的请求有保活窗口（最多 3 分钟）
    func applicationDidEnterBackground(_ application: UIApplication) {
        backgroundTask = application.beginBackgroundTask(withName: "trollmcp2.network") {
            application.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            if self.backgroundTask != .invalid {
                application.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
        // v2.9.136：切后台提交 BGTask 周期刷新（系统调度窗口内保持存活）
        BackgroundKeepAlive.scheduleRefresh()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        BackgroundKeepAlive.cancelRefresh()
    }

    // MARK: v2.9.126 —— 深链导入模型 API 配置（对齐 cc-switch DeepLinkImportDialog）
    // 链接格式: trollagent://import?baseURL=...&apiKey=...&model=...&name=...&auth=Bearer&group=默认
    // 解析后存 pendingImport 并发通知，由 SwiftUI 层弹确认页（防误导入）
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.scheme?.lowercased() == "trollagent" else { return false }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return false }

        func value(_ k: String) -> String? {
            items.first { $0.name == k }?.value?.removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let path = comps.host ?? ""
        if path == "import" {
            let baseURL = value("baseURL") ?? ""
            let apiKey = value("apiKey") ?? ""
            let model = value("model") ?? ""
            guard !baseURL.isEmpty, !model.isEmpty else { return false }
            let name = value("name") ?? model
            let auth = value("auth") ?? "Bearer"
            let group = value("group") ?? "默认"
            let temp = value("temperature").flatMap(Double.init) ?? 0.7
            let maxTokens = value("maxTokens").flatMap(Int.init) ?? 2048
            let context = value("contextTokens").flatMap(Int.init) ?? 16000
            let protocolName = value("protocol") ?? "OpenAI Chat Completions"

            let config = ModelConfig(
                id: UUID(),
                name: name,
                provider: value("provider") ?? "custom",
                apiProtocol: protocolName,
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                authMethod: auth.isEmpty ? "Bearer" : auth,
                isDefault: false,
                temperature: temp,
                maxTokens: maxTokens,
                compatLevel: 0,
                contextTokens: context,
                group: group.isEmpty ? "默认" : group
            )
            PendingImport.shared.stage(config)
            return true
        }
        return false
    }
}
