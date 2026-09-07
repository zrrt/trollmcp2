import Foundation

// MARK: - v2.9.89 紧急救援工具（Residue 式）
//
// 背景：v2.9.88 及更早版本注入直接改主二进制 + 备份后缀不兼容（.bak_macho vs .troll-fools.bak），
// 导致微信注入事故后 TrollFools 无法识别/卸载，只能靠卸载重装（聊天记录丢失）。
// 本组工具提供：单 App 恢复、全机扫描、一键全恢复、残留清理——都是"保命"能力。

/// injection.restore：单 App 恢复——移除注入加载命令、删除注入资产、从备份还原原始 Mach-O
final class InjectionRestoreTool: MCPTool {
    let definition = ToolDefinition(name: "injection.restore",
        summary: "紧急恢复：移除指定 App 的所有注入并还原原始二进制（对齐 TrollFools 卸载策略；注入后 App 打不开时第一选择）",
        parameters: ["bundle_id": "目标 App Bundle ID"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        guard AppCatalog.find(bid) != nil else { throw MCPError.failed("app not found: \(bid)") }
        let r = try InjectionManager.shared.disable(bundleId: bid)
        AuditLog.shared.log("injection.restore", detail: bid)
        var out = r
        out["emergency"] = true
        out["next"] = "若 App 仍无法启动，调用 rescue.cleanup（bundle_id）清理残留，或 rescue.recover_all 一键全恢复"
        return out
    }
}

/// rescue.scan：全机扫描——列出有注入痕迹/备份/损坏的 App，输出风险清单
final class RescueScanTool: MCPTool {
    let definition = ToolDefinition(name: "rescue.scan",
        summary: "紧急扫描：全机检查注入痕迹、损坏二进制与备份状态，返回需恢复的 App 清单",
        parameters: ["query": "按名称/bundle_id 过滤（可选）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let q = (params["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apps = AppCatalog.list()
        var findings: [[String: Any]] = []
        for app in apps {
            if !q.isEmpty, !app.name.localizedCaseInsensitiveContains(q), !app.bundleId.localizedCaseInsensitiveContains(q) { continue }
            let main = InjectionManager.shared.executablePath(app)
            let alt = main + ".troll-fools.bak"
            let legacy = main + ".bak_macho"
            let hasAlt = FileManager.default.fileExists(atPath: alt) || FileManager.default.fileExists(atPath: legacy)
            let assets = InjectionManager.shared.injectedAssets(in: app)
            let modified = InjectionManager.shared.collectModifiedMachOs(app)
            // 损坏检测：文件存在但不是合法 Mach-O
            var damaged = false
            var damagedReason = ""
            if FileManager.default.fileExists(atPath: main) {
                let info = MachOAnalyzer.analyze(main)
                if info == nil || !(info?.valid ?? false) {
                    damaged = true
                    damagedReason = info?.arch == "not-macho" ? "主二进制不是合法 Mach-O（可能被损坏）" : "主二进制读取失败"
                }
            }
            guard hasAlt || !assets.isEmpty || !modified.isEmpty || damaged else { continue }
            findings.append([
                "bundle_id": app.bundleId,
                "name": app.name,
                "sensitive": InjectionManager.isSensitive(app.bundleId),
                "has_backup": hasAlt,
                "injected_assets": assets,
                "modified_machos": modified,
                "damaged": damaged,
                "damaged_reason": damagedReason
            ])
        }
        AuditLog.shared.log("rescue.scan", detail: "found=\(findings.count)")
        return [
            "total_apps": apps.count,
            "findings": findings,
            "count": findings.count,
            "hint": findings.isEmpty ? "未发现注入痕迹或损坏二进制" : "对问题 App 执行 injection.restore（bundle_id）逐项恢复，或直接 rescue.recover_all 一键全恢复"
        ]
    }
}

/// rescue.recover_all：一键全恢复——对所有有备份/损坏的 App 执行恢复
final class RescueRecoverAllTool: MCPTool {
    let definition = ToolDefinition(name: "rescue.recover_all",
        summary: "紧急一键恢复：扫描并自动恢复所有存在注入痕迹或损坏二进制的 App（高风险操作，恢复后可正常启动）")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let apps = AppCatalog.list()
        var results: [[String: Any]] = []
        var restoredCount = 0
        var failed: [[String: Any]] = []
        for app in apps {
            let main = InjectionManager.shared.executablePath(app)
            let alt = main + ".troll-fools.bak"
            let legacy = main + ".bak_macho"
            let hasAlt = FileManager.default.fileExists(atPath: alt) || FileManager.default.fileExists(atPath: legacy)
            let assets = InjectionManager.shared.injectedAssets(in: app)
            let modified = InjectionManager.shared.collectModifiedMachOs(app)
            var damaged = false
            if FileManager.default.fileExists(atPath: main) {
                let info = MachOAnalyzer.analyze(main)
                if info == nil || !(info?.valid ?? false) { damaged = true }
            }
            guard hasAlt || !assets.isEmpty || !modified.isEmpty || damaged else { continue }
            do {
                let r = try InjectionManager.shared.disable(bundleId: app.bundleId)
                let reverted = (r["status"] as? String) == "reverted" || !(r["restored_from_backup"] as? [String] ?? []).isEmpty
                if reverted { restoredCount += 1 }
                results.append([
                    "bundle_id": app.bundleId,
                    "name": app.name,
                    "ok": true,
                    "reverted": reverted,
                    "detail": r["hint"] ?? ""
                ])
            } catch {
                failed.append(["bundle_id": app.bundleId, "name": app.name, "error": "\(error.localizedDescription)"])
            }
        }
        AuditLog.shared.log("rescue.recover_all", detail: "restored=\(restoredCount) failed=\(failed.count)")
        return [
            "restored_count": restoredCount,
            "failed_count": failed.count,
            "results": results,
            "failed": failed,
            "hint": failed.isEmpty ? "全部恢复完成，被恢复的 App 已还原到注入前状态" : "部分 App 恢复失败，请逐项查看 failed 列表后用 injection.restore 重试"
        ]
    }
}

/// rescue.cleanup：清理残留——删除注入标记、孤儿备份、Frameworks 内残留的非系统 dylib
final class RescueCleanupTool: MCPTool {
    let definition = ToolDefinition(name: "rescue.cleanup",
        summary: "清理注入残留：删除 .troll-fools 标记、孤儿备份与 Frameworks 内非系统 dylib（指定 bundle_id 清理单个 App；不指定仅清理全机孤儿备份）",
        parameters: ["bundle_id": "目标 App Bundle ID（可选）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let mgr = InjectionManager.shared
        let bid = params["bundle_id"] as? String
        var cleaned: [String] = []
        var errors: [String] = []

        if let bid = bid, let app = AppCatalog.find(bid) {
            // 单 App 清理：删注入标记 + 备份 + Frameworks 内残留非系统 dylib
            let fm = FileManager.default
            let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
            if fm.fileExists(atPath: frameworksDir),
               let items = try? fm.contentsOfDirectory(atPath: frameworksDir) {
                for item in items {
                    let full = (frameworksDir as NSString).appendingPathComponent(item)
                    let lower = item.lowercased()
                    // 跳过系统/忽略名单
                    if lower.hasPrefix("libswift") || InjectionManager.isSensitiveSystemLibrary(item) { continue }
                    // 删除：注入标记文件、备份文件、非系统 dylib
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isDir)
                    let isMarker = item == ".troll-fools"
                    let isBackup = item.hasSuffix(".troll-fools.bak") || item.hasSuffix(".bak_macho")
                    let isForeignDylib = lower.hasSuffix(".dylib")
                    if isMarker || isBackup || isForeignDylib {
                        _ = mgr.runAsRoot("rm", args: [isDir.boolValue ? "-rf" : "-f", full])
                        cleaned.append("\(app.bundleId):\(item)")
                    }
                }
            }
            let main = mgr.executablePath(app)
            for backup in [main + ".troll-fools.bak", main + ".bak_macho"] {
                if fm.fileExists(atPath: backup) {
                    _ = mgr.runAsRoot("rm", args: ["-f", backup])
                    cleaned.append("\(app.bundleId):\((backup as NSString).lastPathComponent)")
                }
            }
            // 主二进制损坏时尝试从备份恢复（若清理时备份还在）
            let mainInfo = MachOAnalyzer.analyze(main)
            if mainInfo == nil || !(mainInfo?.valid ?? false) {
                if (try? mgr.restoreAlternate(main)) == true {
                    cleaned.append("\(app.bundleId):main_binary_restored")
                } else {
                    errors.append("\(app.bundleId):主二进制损坏且无可用备份，需卸载重装")
                }
            }
        } else {
            // 全机孤儿备份清理：备份文件存在但对应 Mach-O 已不存在的
            for app in AppCatalog.list() {
                let main = mgr.executablePath(app)
                let alt = main + ".troll-fools.bak"
                let legacy = main + ".bak_macho"
                if !FileManager.default.fileExists(atPath: main) {
                    for backup in [alt, legacy] where FileManager.default.fileExists(atPath: backup) {
                        _ = mgr.runAsRoot("rm", args: ["-f", backup])
                        cleaned.append("\(app.bundleId):\((backup as NSString).lastPathComponent)")
                    }
                }
            }
        }
        AuditLog.shared.log("rescue.cleanup", detail: "cleaned=\(cleaned.count) errors=\(errors.count)")
        return [
            "cleaned": cleaned,
            "cleaned_count": cleaned.count,
            "errors": errors,
            "hint": bid == nil ? "已清理全机孤儿备份" : "已清理 \(bid) 的注入残留与损坏二进制"
        ]
    }
}
