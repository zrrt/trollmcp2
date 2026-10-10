import UIKit
import SwiftUI

// 桌面悬浮 HUD 单可执行双模式（TrollSpeed 正解）：主 App 可执行（TrollStore 有效签名）
// 由 HUDManager 以 root persona 拉起，argv 带 -hud 进悬浮模式；-exit/-check 关闭/查存活。
// 符号由 libHUD.a 提供（HUD/sources 编出的 ObjC++ 悬浮核心，HUDApp.mm extern "C" 导出）。
@_silgen_name("HUDMainStart") func HUDMainStart()
@_silgen_name("HUDExit") func HUDExit()
@_silgen_name("HUDCheck") func HUDCheck() -> Int32
@_silgen_name("troll_launch_capture")
func _troll_launch_capture(_ path: UnsafePointer<CChar>, _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>, _ outbuf: UnsafeMutablePointer<CChar>, _ buflen: Int, _ exit_code: UnsafeMutablePointer<Int32>?) -> Int32

@main
struct TrollAgentApp {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("-hud") {
            HUDMainStart()        // 进悬浮模式（内部 runloop，不返回）
        } else if args.contains("-exit") {
            HUDExit()             // 关闭悬浮（读 pid 杀）
        } else if args.contains("-check") {
            exit(HUDCheck())      // 查悬浮存活（EXIT_FAILURE=存活 / EXIT_SUCCESS=未跑）
        } else {
            UIApplicationMain(
                CommandLine.argc,
                CommandLine.unsafeArgv,
                nil,
                NSStringFromClass(AppDelegate.self)
            )
        }
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
        Workspace.ensureBundledTweaks()  // v2.9.62：把内置 dylib（MemoryTweak 等）复制到工作区，AI 可直接 artifact.find 定位
        ConfigMigration.migrateIfNeeded()  // v2.9.126：配置 schema 迁移（防模块脱节：升级后旧配置结构自动搬运）
        ToolRegistry.shared.registerBuiltinTools()
        // v2.9.145：启动探测移到后台——DeviceProbe.run() 含 spawnRoot/文件遍历，
        // 主线程同步跑会卡死启动被看门狗杀（表现为"装完打开就闪退"）
        DispatchQueue.global(qos: .userInitiated).async {
            _ = DeviceProbe.shared.run()
        }
        LocationProvider.shared.start()
        // v2.9.10：网络与生命周期监控（切后台重连 / 网络恢复提示）
        AppLifecycleMonitor.shared.start()
        // fix3cy8：启动即清理残留 VPN 配置（上次异常退出/旧版关 VPN 没删配置 → 残留隧道路由
        // 会把局域网 8790 黑洞；启动时后台查一次，存在残留即删，保证远程通道可靠）
        DispatchQueue.global(qos: .utility).async {
            VpnManager.cleanupStaleConfig()
        }
        // v6.0.x：可爱助手开启则启动自动拉起桌面悬浮 HUD。
        // 直接读 UserDefaults（不经 GirlCompanion.shared 时序），延迟 2s 确保 UI/进程就绪再拉起。
        let girlEnabled = UserDefaults.standard.bool(forKey: "trollmcp2.girl_companion_enabled")
        if girlEnabled {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                _ = HUDManager.shared.start()
            }
        }
        // v6.0.x: Live2D 方案 A 前置验证——启动后以 mobile 身份(继承)拉起沙盒 gputest 测 GPU。
        // 用 troll_launch_capture（管道捕获）：子进程 stdout+stderr dup2 到管道，主 App 读管道 + waitpid。
        // 不受子进程沙盒写文件限制（沙盒连 /var/mobile/Documents 都打不开，addopen 重定向会失败），
        // 崩溃也能捕获已 printf 的输出（BOOT/MTL 结果/EXIT）+ 退出码。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            let gp = Bundle.main.bundlePath + "/gputest"
            if FileManager.default.fileExists(atPath: gp) {
                var argv: [UnsafeMutablePointer<CChar>?] = [strdup(gp), nil]
                let outbuf = UnsafeMutablePointer<CChar>.allocate(capacity: 8192)
                outbuf.initialize(repeating: 0, count: 8192)
                defer { outbuf.deallocate() }
                var ec: Int32 = -999
                let rc = argv.withUnsafeBufferPointer { buf -> Int32 in
                    guard let base = buf.baseAddress else { return -99 }
                    return gp.withCString { cs in _troll_launch_capture(cs, base, outbuf, 8192, &ec) }
                }
                // 主 App no-sandbox 可写全局路径，记录捕获的输出 + 退出码
                let outStr = String(cString: outbuf)
                let log = "gputest capture rc=\(rc) exit=\(ec)\n--- stdout/stderr ---\n\(outStr)\n--- end ---\n"
                try? log.data(using: .utf8)?
                    .write(to: URL(fileURLWithPath: "/var/mobile/Documents/gputest.out"))
            }
        }
        // v4.3.39：启动静默检查更新——后台跑，不打扰；发现新版点亮设置页"检查更新"红点
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
            UpdateManager.shared.checkForUpdate(currentVersion: ver)
        }
        // v2.9.66：启动时上报设备信息到统计后台（安装量/机型分布，需在设置中开启并配置服务器地址）
        DeviceReporter.shared.reportIfNeeded()
        // v2.9.180：远程诊断——启动即开始轮询云端指令；上报安装信息 + 上次崩溃未上报的日志。
        // 只读白名单执行，无危险操作；配置在 设置 → 远程诊断。
        RemoteAgent.shared.start()
        RemoteAgent.shared.reportInstallIfNeeded()
        RemoteAgent.shared.reportPendingCrashes()

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIHostingController(rootView: RootView())
        window?.makeKeyAndVisible()

        // v2.9.136：全局后台常驻开关（设置页「后台常驻」）——开启后 App 启动即启动静音保活引擎，
        // 与远程控制的临时保活互补，长任务/后台等待 AI 结果时不挂起。
        if UserDefaults.standard.bool(forKey: "trollagent.keepalive_global") {
            BackgroundKeepAlive.shared.start()
        }
        // v2.9.136：BGTask 周期唤醒（双保险，系统调度允许时后台刷新）
        BackgroundKeepAlive.registerBGTask()

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
        // v6.0.7：锁屏久了 HUD 进程可能被系统清理；回前台自动检查，若可爱助手开着但悬浮没跑则拉起
        if GirlCompanion.shared.enabled && !HUDManager.shared.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                _ = HUDManager.shared.start()
            }
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
