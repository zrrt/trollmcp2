import Foundation
import UIKit

// v2.9.128：清理中心工具集 (对齐 Fuck 工具箱"清理类"能力 + AI 清理亮点）
// 聚合已有能力：缓存清理 / keychain / 广告符 / 数据容器 / 标识符
// 分层：scan (分析可清理项）→ execute (按项执行）→ ai (AI 全自动清理+验证报告）

struct CleanupItem {
    let id: String          // cache / keychain / adid / container / idfv
    let label: String       // 显示名
    let detail: String      // 说明
    let bytes: Int          // 预估释放
    let risk: Risk          // 影响分级
    enum Risk: String { case safe, warn, danger, error }
    let affected: String    // 影响描述 (登录态/广告符/数据）
}

/// 清理项扫描器 (内部复用现有工具实现）
final class CleanupScanner {
    static func scan(bundleId: String) -> [CleanupItem] {
        var items: [CleanupItem] = []
        guard let app = AppCatalog.find(bundleId), let container = AppCatalog.lookupContainer(bundleId: app.bundleId) else {
            return []   // 调用方处理"未找到/容器不可访问"
        }

        // 1. 缓存 + tmp (安全）
        let caches = URL(fileURLWithPath: container).appendingPathComponent("Library/Caches")
        let tmp = URL(fileURLWithPath: container).appendingPathComponent("tmp")
        let cacheBytes = AppCacheScanner.directorySize(caches) + AppCacheScanner.directorySize(tmp)
        if cacheBytes > 0 {
            items.append(CleanupItem(id: "cache", label: "clean caches and temp files",
                                     detail: "Library/Caches + tmp (\(AppCacheScanner.humanSize(cacheBytes)))",
                                     bytes: cacheBytes, risk: .safe, affected: "no impact, regenerated on next launch"))
        } else {
            items.append(CleanupItem(id: "cache", label: "clean caches and temp files",
                                     detail: "当前无可清理缓存 (0 B)",
                                     bytes: 0, risk: .safe, affected: "无影响"))
        }

        // 2. 钥匙串 (警告——清登录态）
        items.append(CleanupItem(id: "keychain", label: "清钥匙串 (登录态/令牌)",
                                 detail: "按 keychain-access-groups 删除该 App 的密码/令牌/密钥",
                                 bytes: 0, risk: .warn, affected: "清空该 App 登录态，需重新登录"))

        // 3. 广告标识符 (警告——IDFA）
        items.append(CleanupItem(id: "adid", label: "刷新广告标识符 (IDFA)",
                                 detail: "调用私有 API 尝试重置；iOS 14+ 受系统限制时仅提示",
                                 bytes: 0, risk: .warn, affected: "广告符变化，游戏拉新/广告追踪可能重置"))

        // 4. 数据容器 (危险——整体重置，可恢复）
        items.append(CleanupItem(id: "container", label: "刷新数据容器 (重置 App 数据，可恢复)",
                                 detail: "容器改名备份 → 杀进程 → 系统重建空容器；备份可 restore 恢复",
                                 bytes: 0, risk: .danger, affected: "清空所有本地数据 (含未上传存档)，备份保留可恢复"))

        // 5. 标识符 (只读提示）
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? "N/A"
        items.append(CleanupItem(id: "idfv", label: "标识符 (IDFV)",
                                 detail: "系统 \(idfv.prefix(8))…；无公开刷新 API，删除 App 后由系统决定",
                                 bytes: 0, risk: .safe, affected: "只读信息，不执行"))

        return items
    }

    /// 按项执行 (复用现有工具，统一 AuditLog）
    static func execute(bundleId: String, itemIds: [String], dryRun: Bool = false) -> [[String: Any]] {
        var results: [[String: Any]] = []
        for id in itemIds {
            var r: [String: Any] = ["item": id]
            switch id {
            case "cache":
                if let out = try? AppCacheClearTool().invoke(["bundle_id": bundleId, "dry_run": dryRun]) {
                    r["ok"] = true; r["result"] = out
                } else { r["ok"] = false; r["error"] = "cache cleanup failed" }
            case "keychain":
                if dryRun {
                    r["ok"] = true; r["result"] = ["dry_run": true, "note": "will delete all keychain entries of this App"]
                } else if let out = try? KeychainWipeTool().invoke(["bundle_id": bundleId]) {
                    r["ok"] = true; r["result"] = out
                } else { r["ok"] = false; r["error"] = "keychain cleanup failed" }
            case "adid":
                if dryRun {
                    r["ok"] = true; r["result"] = ["dry_run": true, "note": "will try to refresh IDFA"]
                } else if let out = try? AdvertisingTool().invoke(["action": "reset"]) {
                    r["ok"] = true; r["result"] = out
                } else { r["ok"] = false; r["error"] = "IDFA refresh failed" }
            case "container":
                if dryRun {
                    r["ok"] = true; r["result"] = ["dry_run": true, "note": "will backup container and reset (restorable)"]
                } else if let out = try? RefreshContainerTool().invoke(["bundle_id": bundleId, "restore": false]) {
                    r["ok"] = true; r["result"] = out
                } else { r["ok"] = false; r["error"] = "container reset failed" }
            case "idfv":
                r["ok"] = true; r["result"] = ["note": "IDFV has no public refresh API, skipped"]
            default:
                r["ok"] = false; r["error"] = "unknown cleanup item \(id)"
            }
            results.append(r)
        }
        return results
    }
}



