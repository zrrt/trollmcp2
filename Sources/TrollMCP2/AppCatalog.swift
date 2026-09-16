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
        var id: String { bundleId }

        /// 用户 App：路径在 /var/containers/Bundle/Application 下
        var isUser: Bool { path.contains("/var/containers/Bundle/Application") }
        /// 系统 App：/Applications 或 /System/Applications
        var isSystem: Bool { !isUser }
        /// 巨魔/越狱工具：bundle id 白名单前缀
        var isTroll: Bool {
            let trollPrefixes = [
                "wiki.qaq.", "cn.gblw", "com.cokepokes", "net.limneos",
                "com.opa334", "io.opa334", "dev.", "me.alfie", "com.zzanehip",
                "eu.slind", "com.imokhles", "org.coolstar", "com.zidati",
                "com.hackyouriphone", "xyz.skylarmccauley", "com.muirey03"
            ]
            for p in trollPrefixes where bundleId.hasPrefix(p) { return true }
            return false
        }
    }

    static func list() -> [AppEntry] {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") else { return [] }
        guard let m = class_getClassMethod(wsClass, NSSelectorFromString("defaultWorkspace")) else { return [] }
        let fn = unsafeBitCast(method_getImplementation(m), to: (@convention(c) (AnyClass, Selector) -> AnyObject?).self)
        guard let ws = fn(wsClass, NSSelectorFromString("defaultWorkspace")) else { return [] }

        guard let m2 = class_getInstanceMethod(object_getClass(ws), NSSelectorFromString("allInstalledApplications")) else { return [] }
        let fn2 = unsafeBitCast(method_getImplementation(m2), to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self)
        guard let apps = fn2(ws, NSSelectorFromString("allInstalledApplications")) as? [NSObject] else { return [] }

        return apps.compactMap { p in
            let bid = p.value(forKey: "applicationIdentifier") as? String ?? ""
            guard !bid.isEmpty else { return nil }
            let path = (p.value(forKey: "bundleURL") as? URL)?.path ?? ""
            let plist = path.isEmpty ? nil : NSDictionary(contentsOfFile: path + "/Info.plist")
            return AppEntry(
                bundleId: bid,
                name: p.value(forKey: "localizedName") as? String ?? bid,
                path: path,
                containerPath: (p.value(forKey: "dataContainerURL") as? URL)?.path,
                version: plist?["CFBundleShortVersionString"] as? String ?? "",
                execName: plist?["CFBundleExecutable"] as? String ?? ""
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
