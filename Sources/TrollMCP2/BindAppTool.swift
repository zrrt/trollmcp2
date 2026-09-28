import Foundation

// MARK: - v4.1.0 按需选择性绑定 App 数据容器
/// 把指定 App 的数据容器绑进 Alpine（/ios_data_<app>），让 Alpine python3/sqlite3/strings
/// 直接读该 App 的 Documents / Library（内购票据、购买状态等）。
/// 与整棵 /var/mobile 绑定不同：只绑目标 App 容器路径、绝不绑自身容器(rootfs)，
/// 因此无自引用 → 无内核污染 → 不崩溃。是替代"退回原生工具"的更优通道。
final class BindAppTool: MCPTool {
    let definition = ToolDefinition(
        name: "bind_app",
        summary: "按需把指定 App 的数据容器绑定进 Alpine(私有 API 解析容器) → /ios_data_<app>。用于让 Alpine 的 python3/sqlite3/strings 直接读该 App 的 Documents/Library(如内购票据、购买状态、导出文件)。绝不绑 /var/mobile 整棵与自身容器(rootfs)，因此无自引用污染崩溃。Example: bind_app bundle_id:com.appstudio.Jinx → 返回 /ios_data_com_appstudio_jinx，然后 shell.exec(\"python3 /ios_data_com_appstudio_jinx/...\")。Don't use for: 读 App Bundle(用 /ios_containers)。",
        parameters: [
            "bundle_id": "App bundle ID (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let r = ISHEngine.bindAppContainer(bundleId: bundleId)
        guard r.ok, let m = r.mountPath, let h = r.hostPath else {
            throw MCPError.failed("bind_app: \(r.error ?? "unknown error")")
        }
        return [
            "ok": true,
            "bundle_id": bundleId,
            "mount_path": m,
            "host_path": h,
            "hint": "在 Alpine shell.exec / python3 里用 \(m) 直接读该 App 数据(如 \(m)/Documents、\(m)/Library/Preferences)",
        ]
    }
}
