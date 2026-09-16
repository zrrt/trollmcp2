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
        Workspace.ensure()
        Workspace.ensureBundledTweaks()  // v2.9.62：把内置 dylib（MemoryTweak 等）复制到工作区，AI 可直接 artifact.find 定位
        ConfigMigration.migrateIfNeeded()  // v2.9.126：配置 schema 迁移（防模块脱节：升级后旧配置结构自动搬运）
        ToolRegistry.shared.registerBuiltinTools()
        _ = DeviceProbe.shared.run()
        LocationProvider.shared.start()
        // v2.9.10：网络与生命周期监控（切后台重连 / 网络恢复提示）
        AppLifecycleMonitor.shared.start()
        // v2.9.66：启动时上报设备信息到统计后台（安装量/机型分布，需在设置中开启并配置服务器地址）
        DeviceReporter.shared.reportIfNeeded()

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
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
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
                contextTokens: context,
                compatLevel: 0,
                group: group.isEmpty ? "默认" : group
            )
            PendingImport.shared.stage(config)
            return true
        }
        return false
    }
}
