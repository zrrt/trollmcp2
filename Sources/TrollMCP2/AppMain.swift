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
        ToolRegistry.shared.registerBuiltinTools()
        DeviceProbe.shared.run()
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
}
