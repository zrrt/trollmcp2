import Foundation
import UIKit

// v2.9.128：清理中心工具集（对齐 Fuck 工具箱"清理类"能力 + AI 清理亮点）
// 聚合已有能力：缓存清理 / keychain / 广告符 / 数据容器 / 标识符
// 分层：scan（分析可清理项）→ execute（按项执行）→ ai（AI 全自动清理+验证报告）

struct CleanupItem {
    let id: String          // cache / keychain / adid / container / idfv
    let label: String       // 显示名
    let detail: String      // 说明
    let bytes: Int          // 预估释放
    let risk: Risk          // 影响分级
    enum Risk: String { case safe, warn, danger, error }
    let affected: String    // 影响描述（登录态/广告符/数据）
}

/// 清理项扫描器（内部复用现有工具实现）
final class CleanupScanner {
    static func scan(bundleId: String) -> [CleanupItem] {
        var items: [CleanupItem] = []
        guard let app = AppCatalog.find(bundleId), let container = app.containerPath else {
            return []   // 调用方处理"未找到/容器不可访问"
        }

        // 1. 缓存 + tmp（安全）
        let caches = URL(fileURLWithPath: container).appendingPathComponent("Library/Caches")
        let tmp = URL(fileURLWithPath: container).appendingPathComponent("tmp")
        let cacheBytes = AppCacheScanner.directorySize(caches) + AppCacheScanner.directorySize(tmp)
        if cacheBytes > 0 {
            items.append(CleanupItem(id: "cache", label: "清理缓存与临时文件",
                                     detail: "Library/Caches + tmp（\(AppCacheScanner.humanSize(cacheBytes))）",
                                     bytes: cacheBytes, risk: .safe, affected: "无影响，下次启动重新生成"))
        } else {
            items.append(CleanupItem(id: "cache", label: "清理缓存与临时文件",
                                     detail: "当前无可清理缓存（0 B）",
                                     bytes: 0, risk: .safe, affected: "无影响"))
        }

        // 2. 钥匙串（警告——清登录态）
        items.append(CleanupItem(id: "keychain", label: "清钥匙串（登录态/令牌）",
                                 detail: "按 keychain-access-groups 删除该 App 的密码/令牌/密钥",
                                 bytes: 0, risk: .warn, affected: "清空该 App 登录态，需重新登录"))

        // 3. 广告标识符（警告——IDFA）
        items.append(CleanupItem(id: "adid", label: "刷新广告标识符（IDFA）",
                                 detail: "调用私有 API 尝试重置；iOS 14+ 受系统限制时仅提示",
                                 bytes: 0, risk: .warn, affected: "广告符变化，游戏拉新/广告追踪可能重置"))

        // 4. 数据容器（危险——整体重置，可恢复）
        items.append(CleanupItem(id: "container", label: "刷新数据容器（重置 App 数据，可恢复）",
                                 detail: "容器改名备份 → 杀进程 → 系统重建空容器；备份可 restore 恢复",
                                 bytes: 0, risk: .danger, affected: "清空所有本地数据（含未上传存档），备份保留可恢复"))

        // 5. 标识符（只读提示）
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? "N/A"
        items.append(CleanupItem(id: "idfv", label: "标识符（IDFV）",
                                 detail: "系统 \(idfv.prefix(8))…；无公开刷新 API，删除 App 后由系统决定",
                                 bytes: 0, risk: .safe, affected: "只读信息，不执行"))

        return items
    }

    /// 按项执行（复用现有工具，统一 AuditLog）
    static func execute(bundleId: String, itemIds: [String], dryRun: Bool = false) -> [[String: Any]] {
        var results: [[String: Any]] = []
        for id in itemIds {
            var r: [String: Any] = ["item": id]
            switch id {
            case "cache":
                if let out = try? AppCacheClearTool().invoke(["bundle_id": bundleId, "dry_run": dryRun]) {
                    r["ok"] = true; r["result"] = out
                } else { r["ok"] = false; r["error"] = "缓存清理失败" }
            case "keychain":
                if dryRun {
                    r["ok"] = true; r["result"] = ["dry_run": true, "note": "将删除该 App 全部钥匙串条目"]
                } else if let out = try? KeychainWipeTool().invoke(["bundle_id": bundleId]) {
                    r["ok"] = true; r["result"] = out
                } else { r["ok"] = false; r["error"] = "钥匙串清理失败" }
            case "adid":
                if dryRun {
                    r["ok"] = true; r["result"] = ["dry_run": true, "note": "将尝试刷新 IDFA"]
                } else if let out = try? AdvertisingTool().invoke(["action": "reset"]) {
                    r["ok"] = true; r["result"] = out
                } else { r["ok"] = false; r["error"] = "广告符刷新失败" }
            case "container":
                if dryRun {
                    r["ok"] = true; r["result"] = ["dry_run": true, "note": "将备份容器并重置（可恢复）"]
                } else if let out = try? RefreshContainerTool().invoke(["bundle_id": bundleId, "restore": false]) {
                    r["ok"] = true; r["result"] = out
                } else { r["ok"] = false; r["error"] = "容器刷新失败" }
            case "idfv":
                r["ok"] = true; r["result"] = ["note": "IDFV 无公开刷新 API，跳过"]
            default:
                r["ok"] = false; r["error"] = "未知清理项 \(id)"
            }
            results.append(r)
        }
        return results
    }
}

// MARK: - cleanup.scan：分析可清理项

final class CleanupScanTool: MCPTool {
    let definition = ToolDefinition(
        name: "cleanup.scan",
        summary: "扫描指定 App 的可清理项（缓存/钥匙串/广告符/数据容器/标识符），返回分项列表与风险分级（safe/warn/danger），供 cleanup.execute 或 cleanup.ai 使用",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let items = CleanupScanner.scan(bundleId: bundleId)
        guard !items.isEmpty else {
            return ["ok": false, "message": "无法定位 \(bundleId) 或数据容器不可访问（缺 AppDataContainers 权限）",
                    "data": ["bundle_id": bundleId, "items": []]]
        }
        let payload = items.map { i -> [String: Any] in
            ["id": i.id, "label": i.label, "detail": i.detail,
             "bytes": i.bytes, "bytes_readable": AppCacheScanner.humanSize(i.bytes),
             "risk": i.risk.rawValue, "affected": i.affected]
        }
        let safe = items.filter { $0.risk == .safe }.count
        let warn = items.filter { $0.risk == .warn }.count
        let danger = items.filter { $0.risk == .danger }.count
        let totalBytes = items.reduce(0) { $0 + $1.bytes }
        return [
            "ok": true,
            "message": "扫描完成：\(items.count) 项（安全 \(safe) / 警告 \(warn) / 危险 \(danger)），可释放 \(AppCacheScanner.humanSize(totalBytes))",
            "data": ["bundle_id": bundleId, "items": payload, "total_bytes": totalBytes,
                     "risk_counts": ["safe": safe, "warn": warn, "danger": danger]]
        ]
    }
}

// MARK: - cleanup.execute：按指定项执行清理

final class CleanupExecuteTool: MCPTool {
    let definition = ToolDefinition(
        name: "cleanup.execute",
        summary: "执行清理：按 items 指定项清理指定 App（cache/keychain/adid/container/idfv）。risk=danger 的 container 会重置全部数据（自动备份可恢复）。dry_run=true 只预览不执行",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "items": "要执行的清理项数组，如 [\"cache\",\"keychain\"]（必填）",
            "dry_run": "可选：true 只预览不执行（默认 false）"
        ], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let items = params["items"] as? [String], !items.isEmpty else {
            throw MCPError.invalidParams("items required (e.g. [\"cache\",\"keychain\"])")
        }
        let dryRun = (params["dry_run"] as? Bool) ?? false
        let results = CleanupScanner.execute(bundleId: bundleId, itemIds: items, dryRun: dryRun)
        let failed = results.filter { ($0["ok"] as? Bool) != true }.count
        return [
            "ok": failed == 0,
            "message": dryRun ? "预览完成（未执行）：\(results.count) 项" : "清理完成：\(results.count - failed) 项成功，\(failed) 项失败",
            "data": ["bundle_id": bundleId, "dry_run": dryRun, "results": results]
        ]
    }
}

// MARK: - cleanup.ai：AI 全自动清理（亮点功能）

final class CleanupAiTool: MCPTool {
    let definition = ToolDefinition(
        name: "cleanup.ai",
        summary: "AI 全自动清理指定 App：扫描可清理项 → 按风险执行（默认只清 safe；auto=true 连 warn 也清；danger 项除非 confirm=true 否则跳过）→ 重新扫描验证 → 输出报告。适合「一键清理」",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "auto": "可选：true 连警告级（钥匙串/广告符）一起清（默认 false 只清安全项）",
            "confirm": "可选：true 才允许执行危险级（数据容器重置，自动备份）（默认 false）"
        ],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let auto = (params["auto"] as? Bool) ?? false
        let confirm = (params["confirm"] as? Bool) ?? false

        // 1. 扫描
        let scanned = CleanupScanner.scan(bundleId: bundleId)
        guard !scanned.isEmpty else {
            return ["ok": false, "message": "无法定位 \(bundleId) 或数据容器不可访问（缺 AppDataContainers 权限）",
                    "data": ["bundle_id": bundleId]]
        }
        // 2. 决定执行项
        var toRun: [String] = []
        var skipped: [[String: Any]] = []
        for item in scanned {
            switch item.risk {
            case .safe:
                if item.id != "idfv" { toRun.append(item.id) }   // idfv 只读
            case .warn:
                if auto { toRun.append(item.id) }
                else { skipped.append(["id": item.id, "reason": "警告级，需 auto=true", "affected": item.affected]) }
            case .danger:
                if confirm { toRun.append(item.id) }
                else { skipped.append(["id": item.id, "reason": "危险级（重置全部数据），需 confirm=true", "affected": item.affected]) }
            case .error:
                skipped.append(["id": item.id, "reason": item.detail])
            }
        }
        // 3. 执行
        var executed: [[String: Any]] = []
        if !toRun.isEmpty {
            executed = CleanupScanner.execute(bundleId: bundleId, itemIds: toRun)
        }
        // 4. 验证：重新扫描
        let after = CleanupScanner.scan(bundleId: bundleId)
        let freed = scanned.filter { toRun.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        let failedCount = executed.filter { ($0["ok"] as? Bool) != true }.count

        return [
            "ok": failedCount == 0,
            "message": "AI 清理完成：执行 \(executed.count) 项（成功 \(executed.count - failedCount)），释放 \(AppCacheScanner.humanSize(freed))，跳过 \(skipped.count) 项",
            "data": [
                "bundle_id": bundleId,
                "executed": executed,
                "skipped": skipped,
                "freed_bytes": freed,
                "freed_readable": AppCacheScanner.humanSize(freed),
                "verification": [
                    "note": "重新扫描结果：缓存类已清零则验证通过",
                    "cache_remaining": after.first(where: { $0.id == "cache" })?.bytes ?? 0,
                    "risk_counts": ["safe": after.filter { $0.risk == .safe }.count,
                                    "warn": after.filter { $0.risk == .warn }.count,
                                    "danger": after.filter { $0.risk == .danger }.count]
                ]
            ]
        ]
    }
}
