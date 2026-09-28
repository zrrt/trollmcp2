import Foundation

// MARK: - v2.9.141 跨 App 数据桥 (沙箱破坏者）
// 通行证：no-sandbox + AppDataContainers 权限 → 可读写任意 App 的 Bundle/数据容器
// 容器定位：解析 /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist
// (与 TrollFools/Residue 同法，纯文件操作无私有 API 依赖）

enum AppContainer {
    /// 数据容器路径 (bundle_id → /var/mobile/Containers/Data/Application/<UUID>）
    static func dataContainer(for bundleId: String) -> String? {
        let root = "/var/mobile/Containers/Data/Application"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for uuid in entries where uuid.count == 36 {
            let meta = root + "/" + uuid + "/.com.apple.mobile_container_manager.metadata.plist"
            guard let dict = NSDictionary(contentsOfFile: meta),
                  let bid = dict["MCMMetadataIdentifier"] as? String, bid == bundleId else { continue }
            return root + "/" + uuid
        }
        return nil
    }

    /// Bundle 路径 (走 AppCatalog 缓存枚举）
    static func bundlePath(for bundleId: String) -> String? {
        AppCatalog.list().first { $0.bundleId == bundleId }?.path
    }

    /// 解析 scope 到实际路径
    static func resolve(bundleId: String, scope: String, path: String) -> (ok: Bool, full: String?, reason: String) {
        let root: String
        if scope == "bundle" {
            guard let bp = bundlePath(for: bundleId) else {
                return (false, nil, "App bundle not found (confirm bundle_id)")
            }
            root = bp
        } else if scope == "data" {
            guard let dp = dataContainer(for: bundleId) else {
                return (false, nil, "data container not found (App may never have run or is uninstalled)")
            }
            root = dp
        } else {
            return (false, nil, "scope only supports bundle/data")
        }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let full = root + (cleaned.isEmpty ? "" : "/" + cleaned)
        // 防越界：禁止逃出容器根
        guard full.hasPrefix(root + "/") || full == root else {
            return (false, nil, "path out of bounds (container access only)")
        }
        return (true, full, "")
    }

    /// 目录大小
    static func size(of path: String) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let p as String in enumerator {
                let full = path + "/" + p
                if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                   let size = attrs[.size] as? Int64 {
                    bytes += size
                }
                files += 1
            }
        }
        return (bytes, files)
    }

    static func human(_ b: Int64) -> String {
        let f = Double(b)
        if f >= 1_073_741_824 { return String(format: "%.2f GB", f / 1_073_741_824) }
        if f >= 1_048_576 { return String(format: "%.2f MB", f / 1_048_576) }
        if f >= 1024 { return String(format: "%.1f KB", f / 1024) }
        return "\(b) B"
    }
}
