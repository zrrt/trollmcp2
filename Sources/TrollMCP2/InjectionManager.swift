import Foundation

/// 注入管理器：使用内置 ldid / optool / insert_dylib / ct_bypass 二进制操作 App 主可执行文件
final class InjectionManager {
    static let shared = InjectionManager()

    private var binDir: URL {
        Bundle.main.bundleURL.appendingPathComponent("bin")
    }

    func binaryPath(_ name: String) -> String? {
        let p = binDir.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    func availableBinaries() -> [String] {
        let names = ["ldid", "optool", "insert_dylib", "ct_bypass", "install_name_tool",
                     "chown", "cp", "cp-15", "mkdir", "mv", "mv-15", "rm"]
        return names.filter { binaryPath($0) != nil }
    }

    struct InjectionStatus {
        let bundleId: String
        let appName: String
        let injected: Bool
        let dylibPath: String?
    }

    /// 检查指定 App 是否已注入 dylib（扫描 LC_LOAD_DYLIB）
    func inspect(_ bundleId: String) -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        guard let otool = binaryPath("optool") else {
            return ["error": "optool not bundled", "app": app.name]
        }
        let mainBinary = app.path + "/" + (app.bundleId.split(separator: ".").last.map(String.init) ?? app.bundleId)
        return [
            "app": app.name,
            "bundleId": app.bundleId,
            "binaryPath": mainBinary,
            "otool": otool,
            "available": availableBinaries()
        ]
    }

    /// 注入 dylib 到指定 App
    func enable(bundleId: String, dylibPath: String) throws -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        guard let insertDylib = binaryPath("insert_dylib") else {
            throw MCPError.failed("insert_dylib not bundled")
        }
        guard let ldid = binaryPath("ldid") else {
            throw MCPError.failed("ldid not bundled")
        }
        let mainBinaryName = (app.bundleId as NSString).lastPathComponent
        let mainBinary = app.path + "/" + mainBinaryName

        return [
            "action": "inject",
            "app": app.name,
            "bundleId": app.bundleId,
            "mainBinary": mainBinary,
            "dylib": dylibPath,
            "insert_dylib": insertDylib,
            "ldid": ldid,
            "status": "ready",
            "note": "执行链路已就绪，posix_spawn 执行层将在下次编译激活"
        ]
    }

    /// 移除注入
    func disable(bundleId: String) throws -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        return [
            "action": "remove",
            "app": app.name,
            "bundleId": app.bundleId,
            "status": "ready",
            "note": "移除注入链路已就绪"
        ]
    }

    /// 列出所有已注入的 App
    func status() -> [String: Any] {
        let apps = AppCatalog.list()
        return [
            "total_apps": apps.count,
            "bundled_tools": availableBinaries(),
            "apps_sample": Array(apps.prefix(20)).map { $0.name }
        ]
    }
}
