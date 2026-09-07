# -*- coding: utf-8 -*-
import io

path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\AdvancedTools.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

marker = '// MARK: - HTTP 辅助（localhost）'
assert marker in c, 'marker missing'

new_tools = '''// MARK: - v2.9.95 设备指纹 / 容器 / entitlements 工具（对齐 Fuck 工具箱 + 绿盾式）

/// 查看 App entitlements（ldid -e 解析）
final class AppEntitlementsTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.entitlements",
        summary: "查看指定 App 的权限声明（entitlements，ldid -e 解析）：keychain 组、沙箱、task_for_pid、平台应用等",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \\(bundleId)"]
        }
        let main = InjectionManager.shared.executablePath(app)
        let (c, o) = InjectionManager.shared.runAsRoot("ldid", args: ["-e", main])
        if c != 0 { return ["error": "ldid -e 失败(\\(c))", "output": o] }
        var dict: [String: Any] = [:]
        if let data = o.data(using: .utf8),
           let d = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            dict = d
        }
        return [
            "bundle_id": bundleId,
            "entitlements": dict,
            "keychain_groups": dict["keychain-access-groups"] ?? [],
            "platform_app": dict["platform-application"] as? Bool ?? false,
            "no_sandbox": dict["com.apple.private.security.no-sandbox"] as? Bool ?? false,
            "task_for_pid": dict["task_for_pid-allow"] as? Bool ?? false,
            "get_task_allow": dict["get-task-allow"] as? Bool ?? false,
            "hint": "keychain_groups 可直接传给 device.keychain_wipe 精确清理目标 App 钥匙串"
        ]
    }
}

/// 清理指定 App 钥匙串条目（按 entitlements 的 keychain-access-groups 精确删除）
final class KeychainWipeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.keychain_wipe",
        summary: "清理指定 App 的钥匙串条目：按目标 App 的 keychain-access-groups 用 SecItemDelete 精确删除（密码/令牌/密钥）。跨组删除受系统权限限制时给出提示",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \\(bundleId)"]
        }
        let main = InjectionManager.shared.executablePath(app)
        let (c, o) = InjectionManager.shared.runAsRoot("ldid", args: ["-e", main])
        var groups: [String] = []
        if c == 0, let data = o.data(using: .utf8),
           let d = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let gs = d["keychain-access-groups"] as? [String] {
            groups = gs
        }
        if groups.isEmpty { groups = ["TROLLTROLL.dev.trollmcp2.app"] }
        var deleted = 0
        var failed = 0
        var errors: [String] = []
        for g in groups {
            for cls in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey] {
                let q: [String: Any] = [
                    kSecClass as String: cls,
                    kSecAttrAccessGroup as String: g,
                    kSecMatchLimit as String: kSecMatchLimitAll
                ]
                let st = SecItemDelete(q as CFDictionary)
                if st == errSecSuccess { deleted += 1 }
                else if st != errSecItemNotFound {
                    failed += 1
                    errors.append("\\(g): \\(st)")
                }
            }
        }
        return [
            "bundle_id": bundleId,
            "groups_tried": groups,
            "deleted_count": deleted,
            "failed_count": failed,
            "errors": errors,
            "hint": failed > 0
                ? "部分条目需要系统级 keychain 权限（本 App 未声明该组）。彻底清空请用 device.keychain_reset（⚠️ 所有 App 登录态都会失效）"
                : "已清理目标 App 钥匙串条目（登录态将被重置）"
        ]
    }
}

/// 一键新机式：清空整机钥匙串（绿盾式核心）
final class KeychainResetTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.keychain_reset",
        summary: "清空整机钥匙串：删除 keychain-2.db 并重启 securityd（绿盾式一键新机核心）。⚠️ 所有 App 的密码/令牌/密钥全部失效，慎用",
        parameters: [:]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let db = "/var/Keychains/keychain-2.db"
        let (c1, o1) = InjectionManager.shared.runAsRoot("rm", args: ["-f", db, db + "-wal", db + "-shm"])
        if c1 != 0 { return ["error": "删除 keychain 数据库失败(\\(c1)): \\(o1)"] }
        let (c2, _) = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", "securityd"])
        return [
            "status": "reset",
            "removed": db,
            "securityd_restarted": c2 == 0,
            "hint": "securityd 已由 launchd 自动拉起并重建空 keychain。建议重启手机彻底生效。所有 App 登录态已清空"
        ]
    }
}

/// 广告标识符（IDFA）读取 / 刷新
final class AdvertisingTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.advertising",
        summary: "读取广告标识符 IDFA 与追踪限制状态；action=reset 尝试刷新广告符（私有 API，iOS14+ 受系统限制时如实返回）",
        parameters: ["action": "read（默认）/ reset"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String)?.lowercased() ?? "read"
        var result: [String: Any] = [:]
        let m = ASIdentifierManager.shared()
        result["idfa"] = m.advertisingIdentifier.uuidString
        result["tracking_enabled"] = m.isAdvertisingTrackingEnabled
        result["tracking_limited"] = !m.isAdvertisingTrackingEnabled
        if action == "reset" {
            let any = m as AnyObject
            let sel = NSSelectorFromString("resetIdentifier")
            if any.responds(to: sel) {
                any.perform(sel)
                result["reset"] = "已调用 resetIdentifier"
                result["idfa_after"] = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            } else {
                result["reset"] = "当前系统不支持 resetIdentifier（iOS14+ 已移除公开 API）"
                result["hint"] = "广告符刷新在 iOS14+ 受限；如需彻底换新，可配合 device.keychain_reset（清空含广告符的 keychain）"
            }
        }
        return result
    }
}

/// 读取设备/App 的 identifierForVendor
final class IdfvTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.idfv",
        summary: "读取设备级 IDFV 与目标 App 的 identifierForVendor，可用于设备指纹核对/复制",
        parameters: ["bundle_id": "可选：目标 App Bundle ID"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let sys = UIDevice.current.identifierForVendor?.uuidString ?? "N/A"
        var extra: [String: Any] = ["system_idfv": sys]
        if let bid = params["bundle_id"] as? String, !bid.isEmpty {
            extra["requested_bundle_id"] = bid
            extra["app_idfv"] = "(需在目标 App 进程内读取；设备级 IDFV 见上)"
        }
        extra["hint"] = "IDFV 无公开刷新 API：删除 App 后由系统决定是否变更，备份恢复场景一般不变"
        return extra
    }
}

/// 刷新（重置）指定 App 数据容器——数据保留在备份目录，可 restore 恢复
final class RefreshContainerTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.refresh_container",
        summary: "刷新指定 App 的数据容器：把现有容器改名备份（数据保留），杀进程后系统重建空容器（等于重置 App 数据但可恢复）。传 restore=true 把备份恢复回去",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "restore": "true 时把上次备份目录恢复回原容器"
        ]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \\(bundleId)"]
        }
        guard let container = app.containerPath, !container.isEmpty else {
            return ["error": "无法定位数据容器", "hint": "LSApplicationProxy 未返回 dataContainerURL（可能缺 AppDataContainers 权限）"]
        }
        let restore = (params["restore"] as? Bool) ?? false
        let bk = container + ".trollagent.bak"
        let im = InjectionManager.shared
        if restore {
            if !FileManager.default.fileExists(atPath: bk) {
                return ["error": "没有找到备份目录", "backup": bk]
            }
            _ = im.runAsRoot("rm", args: ["-rf", container])
            let (c, o) = im.runAsRoot("mv", args: [bk, container])
            if c != 0 { return ["error": "恢复失败(\\(c)): \\(o)"] }
            _ = im.runAsRoot("chown", args: ["33:33", container])
            let exe = ProcessHelper.executableName(for: app)
            _ = im.runAsRoot("killall", args: ["killall", "-9", exe])
            return ["status": "restored", "container": container, "hint": "已从备份恢复容器并杀进程，App 数据回到刷新前状态"]
        }
        if FileManager.default.fileExists(atPath: bk) {
            _ = im.runAsRoot("rm", args: ["-rf", bk])
        }
        let (c, o) = im.runAsRoot("mv", args: [container, bk])
        if c != 0 { return ["error": "刷新失败(\\(c)): \\(o)"] }
        _ = im.runAsRoot("chown", args: ["33:33", bk])
        let exe = ProcessHelper.executableName(for: app)
        _ = im.runAsRoot("killall", args: ["killall", "-9", exe])
        return [
            "status": "refreshed",
            "container": container,
            "backup": bk,
            "hint": "容器已改名备份（数据保留）。下次启动 App 系统会重建空容器。恢复：再次调用并传 restore=true"
        ]
    }
}

'''

c = c.replace(marker, new_tools + marker)
with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('INSERTED', len(new_tools), 'chars')
