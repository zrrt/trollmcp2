import Foundation

// MARK: - v4.1.0/v4.2.0 按需选择性绑定 App 数据容器
/// 把指定 App 的数据容器绑进 Alpine（/ios_data_<app>），让 Alpine python3/sqlite3/strings
/// 直接读写该 App 的 Documents / Library（内购票据、购买状态等）。
/// 与整棵 /var/mobile 绑定不同：只绑目标 App 容器路径、绝不绑自身容器(rootfs)，
/// 因此无自引用 → 无内核污染 → 不崩溃。
///
/// v4.2.0 双模式：
/// - bind_app（只读）：分析用。AI 可读 App 数据容器，但物理上写不进去 → 永不可能写坏目标 App。
/// - bind_app_write（可写+备份）：就地修改用。绑定前先把该 App 的 Documents+Library 备份到
///   工作区 backups/，可写后可改数据（改状态/数值），改坏了可从备份还原。

/// 只读模式：分析 App 数据容器（安全，写不进去）
final class BindAppTool: MCPTool {
    let definition = ToolDefinition(
        name: "bind_app",
        summary: "只读绑定指定 App 数据容器进 Alpine → /ios_data_<app>。参数 bundle_id。让 python3/sqlite3/strings 只读该 App Documents/Library(内购票据/购买状态/导出文件); 读得到写不进去, 永不写坏目标 App。要就地改数据用 bind_app_write(可写+先备份); 读 App Bundle 用 /ios_containers。",
        parameters: [
            "bundle_id": "App bundle ID (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let r = ISHEngine.bindAppContainer(bundleId: bundleId, readOnly: true)
        guard r.ok, let m = r.mountPath, let h = r.hostPath else {
            throw MCPError.failed("bind_app: \(r.error ?? "unknown error")")
        }
        return [
            "ok": true,
            "bundle_id": bundleId,
            "mode": "read_only",
            "mount_path": m,
            "host_path": h,
            "hint": "只读挂载。在 Alpine shell.exec / python3 里用 \(m) 读该 App 数据(如 \(m)/Documents、\(m)/Library/Preferences)。只读，写不进去。",
        ]
    }
}

/// 可写模式：就地修改 App 数据容器（绑定前强制备份到工作区）
final class BindAppWriteTool: MCPTool {
    let definition = ToolDefinition(
        name: "bind_app_write",
        summary: "可写按需绑定指定 App 的数据容器进 Alpine → /ios_data_<app>，用于【就地修改】该 App 的数据(改内购状态/数值/设置/票据)。绑定前先把该 App 的 Documents+Library 自动备份到工作区 backups/，改坏了可从备份还原。风险：写坏该 App 数据容器→该 App 可能无法启动(仅影响目标App, 不影响AI环境)。绝【不】绑自身容器与整棵 /var/mobile(自引用崩溃源)。分析只读用 bind_app。Example: bind_app_write bundle_id:com.appstudio.Jinx → /ios_data_com_appstudio_jinx + backup 路径。",
        parameters: [
            "bundle_id": "App bundle ID (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let r = ISHEngine.bindAppContainer(bundleId: bundleId, readOnly: false)
        guard r.ok, let m = r.mountPath, let h = r.hostPath else {
            throw MCPError.failed("bind_app_write: \(r.error ?? "unknown error")")
        }
        return [
            "ok": true,
            "bundle_id": bundleId,
            "mode": "read_write",
            "mount_path": m,
            "host_path": h,
            "backup_path": r.backupPath ?? "",
            "warning": "可写：改坏该 App 数据容器→该 App 可能无法启动(不影响AI环境)。改动前务必确认已备份(见 backup_path)，改坏了从备份还原。",
        ]
    }
}
