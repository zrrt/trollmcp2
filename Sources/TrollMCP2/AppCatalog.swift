import Foundation
import ObjectiveC

/// 枚举设备已安装 App（通过 LSApplicationWorkspace 私有 API，TrollStore 环境下可用）
/// v2.9.128：AppEntry 扩展 version / execName / 类型分类（对齐 Fuck 工具箱应用管理）
final class AppCatalog {
    struct AppEntry: Identifiable, Hashable {
        let bundleId: String
        let name: String
        let path: String
        let containerPath: String?
        let version: String
        let execName: String
        /// LSApplicationProxy.applicationType："User"（App Store 装）/ "System"
        let appType: String
        /// 签名 TeamID（TrollStore 侧载为 TROLLTROLL）
        let teamID: String?
        var id: String { bundleId }

        /// 用户 App（App Store / 企业签名）：LS 类型 = User
        var isUser: Bool { appType == "User" }
        /// 系统 App：路径不在第三方容器（正常已被过滤，不出现）
        var isSystem: Bool { !path.contains("/var/containers/Bundle/Application") }
        /// 巨魔 TrollStore 侧载：LS 类型 = System（系统 App 已被路径过滤，
        /// 剩余 System 即 TrollStore 装）；teamID=TROLLTROLL 兜底
        var isTroll: Bool { appType == "System" || (teamID?.uppercased().contains("TROLL") ?? false) }
    }

    /// v2.9.135：全量枚举缓存（TTL 5 秒）——旧版每次 list() 都重新枚举 266 个 App，
    /// AI 连续调用 injection.list / app.diagnose 等会反复全量扫描，慢且耗资源。
    /// 运行中集合（runningExecNames）不缓存，每次实时查（变化频繁且查询轻量）。
    private static var cachedList: [AppEntry]?
    private static var cachedAt: Date?
    // v2.9.148：枚举锁——后台 DeviceProbe 与主线程 UI 会同时 list()，
    // LSApplicationWorkspace 私有 API 并发枚举 266 个 App 会 SIGSEGV 闪退
    private static let listLock = NSLock()

    static func list() -> [AppEntry] {
        listLock.lock()
        defer { listLock.unlock() }
        if let cached = cachedList, let at = cachedAt,
           Date().timeIntervalSince(at) < 5 {
            return cached
        }
        let fresh = enumerate()
        cachedList = fresh
        cachedAt = Date()
        return fresh
    }

    /// v2.9.144：可启动判定——过滤系统服务、扩展、无界面 daemon、隐藏 App。
    /// 特征：.appex 扩展 / ViewService·UIService·Extension·XPCService / isHidden=true
    static func isLaunchable(bundleId: String, path: String, proxy: NSObject?) -> Bool {
        if path.contains(".appex") { return false }
        // v2.9.159：系统自带 App（root 分区 /System /Applications）不展示——
        // 只保留第三方容器 App（App Store / TrollStore / 企业签名）。
        // 注意 bundleURL 在部分 iOS 版本返回 /private/var/containers/...（/var 是符号链接），
        // 前缀必须兼容 /private/var 与 /var 两种形态，否则全部 App 被过滤（列表空+环境检测误报）。
        let containerPrefixes = [
            "/var/containers/Bundle/Application/",
            "/private/var/containers/Bundle/Application/"
        ]
        if !containerPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        let lower = bundleId.lowercased()
        let serviceHints = ["viewservice", "uiservice", "xpcservice", "extension",
                            "intents", "widget", "share", "watchapp", "messagesextension",
                            "remotewebsheet", "webapp"]
        for h in serviceHints where lower.contains(h) { return false }
        // 系统 UI 服务/接收器（无主界面，不可交互）
        let daemonHints = ["airdropui", "airplayreceiver", "tvremoteuiservice",
                           "amsengagementviewservice", "accountauthentication",
                           "aauiviewservice", "mediaservice", "companionlink"]
        for h in daemonHints where lower.contains(h) { return false }
        // 隐藏 App（safeValue 已做 responds 保护）
        if let proxy = proxy, let hidden = safeValue(proxy, "isHidden") as? Bool, hidden {
            return false
        }
        return true
    }

    /// v2.9.160：安全 KVC——先 responds 检查再用 method 调用。
    /// 裸 value(forKey:) 对不存在的 key 会抛 NSUnknownKeyException 导致整页闪退
    /// （158 的 applicationType/teamID 读取就是此问题）。LSApplicationProxy 属性均为对象类型。
    private static func safeValue(_ obj: NSObject, _ key: String) -> Any? {
        let sel = NSSelectorFromString(key)
        guard obj.responds(to: sel),
              let m = class_getMethodImplementation(type(of: obj), sel) else { return nil }
        typealias GetFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let fn = unsafeBitCast(m, to: GetFn.self)
        return fn(obj, sel)
    }

    /// 强制刷新（安装/卸载 App 后由调用方触发，避免旧缓存误导）
    static func invalidateCache() {
        listLock.lock()
        cachedList = nil
        cachedAt = nil
        listLock.unlock()
    }

    private static func enumerate() -> [AppEntry] {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") else { return [] }
        guard let m = class_getClassMethod(wsClass, NSSelectorFromString("defaultWorkspace")) else { return [] }
        let fn = unsafeBitCast(method_getImplementation(m), to: (@convention(c) (AnyClass, Selector) -> AnyObject?).self)
        guard let ws = fn(wsClass, NSSelectorFromString("defaultWorkspace")) else { return [] }

        guard let m2 = class_getInstanceMethod(object_getClass(ws), NSSelectorFromString("allInstalledApplications")) else { return [] }
        let fn2 = unsafeBitCast(method_getImplementation(m2), to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self)
        guard let apps = fn2(ws, NSSelectorFromString("allInstalledApplications")) as? [NSObject] else { return [] }

        return apps.compactMap { (p: NSObject) -> AppEntry? in
            let bid = safeValue(p, "applicationIdentifier") as? String ?? ""
            guard !bid.isEmpty else { return nil as AppEntry? }
            let path = (safeValue(p, "bundleURL") as? URL)?.path ?? ""
            let plist = path.isEmpty ? nil : NSDictionary(contentsOfFile: path + "/Info.plist")
            // v2.9.144：过滤系统服务/隐藏应用（ViewService/UIService/Extension/无界面 daemon），
            // 避免"全部"列表混入 AAUIViewService、AirDropUI 之类不可交互条目
            guard isLaunchable(bundleId: bid, path: path, proxy: p) else { return nil }
            // v2.9.158：对齐 TrollFools——LSApplicationProxy.applicationType 区分
            // "User"（App Store 装）/ "System"（TrollStore 侧载，系统 App 已被路径过滤）；
            // teamID 兜底（TrollStore 重签名为 TROLLTROLL）
            let appType: String = (safeValue(p, "applicationType") as? String)
                ?? (path.contains("/var/containers/Bundle/Application") ? "User" : "System")
            let teamID: String? = safeValue(p, "teamID") as? String
            return AppEntry(
                bundleId: bid,
                name: safeValue(p, "localizedName") as? String ?? bid,
                path: path,
                containerPath: (safeValue(p, "dataContainerURL") as? URL)?.path,
                version: plist?["CFBundleShortVersionString"] as? String ?? "",
                execName: plist?["CFBundleExecutable"] as? String ?? "",
                appType: appType,
                teamID: teamID
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func find(_ bundleId: String) -> AppEntry? {
        list().first(where: { $0.bundleId == bundleId })
    }

    /// v2.9.128：运行中 App 的可执行名集合（ps -ax，匹配 execName；兼容 16 字符截断）
    static func runningExecNames() -> Set<String> {
        var set = Set<String>()
        let (_, out) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-ax"], timeout: 10)
        for line in out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // 取行尾的命令名（ps -ax 输出最后一段是命令/参数）
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if let cmd = parts.last {
                set.insert(String(cmd.prefix(16)))
            }
        }
        return set
    }
}
