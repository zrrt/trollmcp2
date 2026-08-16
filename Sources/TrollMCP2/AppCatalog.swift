import Foundation
import ObjectiveC

/// 枚举设备已安装 App（通过 LSApplicationWorkspace 私有 API，TrollStore 环境下可用）
final class AppCatalog {
    struct AppEntry: Identifiable, Hashable {
        let bundleId: String
        let name: String
        let path: String
        let containerPath: String?
        var id: String { bundleId }
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
            return AppEntry(
                bundleId: bid,
                name: p.value(forKey: "localizedName") as? String ?? bid,
                path: (p.value(forKey: "bundleURL") as? URL)?.path ?? "",
                containerPath: (p.value(forKey: "dataContainerURL") as? URL)?.path
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func find(_ bundleId: String) -> AppEntry? {
        list().first(where: { $0.bundleId == bundleId })
    }
}
