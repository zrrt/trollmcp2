import Foundation
import UIKit

// v2.9.131：AI 安装/卸载 App——补全"下载 IPA → 安装 → 注入 → 启动 → 控制"全链路
// TrollStore 官方 trollstorehelper 静默安装优先（/var/usr/bin/trollstorehelper），
// 不存在或失败时降级 trollstore:// URL scheme 调起 TrollStore 确认安装

final class AppInstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.install",
        summary: "安装 IPA 到设备：TrollStore 官方 trollstorehelper 静默安装优先，不可用时自动调起 TrollStore 确认安装。ipa_path 传本地 ipa 绝对路径（工作区下载的 ipa 可直接用）。安装成功后 AI 可继续注入/启动/控制。",
        parameters: ["ipa_path": "本地 ipa 绝对路径（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["ipa_path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("app.install 需要 ipa_path 参数")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return ["ok": false, "error": "文件不存在: \(path)"]
        }
        let im = InjectionManager.shared
        let helper = "/var/usr/bin/trollstorehelper"

        // 方式1：trollstorehelper 静默安装
        if FileManager.default.isExecutableFile(atPath: helper) {
            let (c, out) = im.spawnRoot(helper, args: ["install", path], timeout: 180)
            if c == 0 {
                AuditLog.shared.log("app.install", detail: "\(path) → trollstorehelper 成功")
                AppCatalog.invalidateCache()   // v2.9.135: 安装后失效应用缓存
                return ["ok": true, "method": "trollstorehelper", "output": out,
                        "message": "已静默安装 \(path)"]
            }
            // 失败降级 URL scheme
            let msg = installViaScheme(path)
            return ["ok": msg.ok, "method": msg.ok ? "trollstore://" : "trollstorehelper_failed",
                    "output": out, "message": "trollstorehelper 失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))。\(msg.message)"]
        }

        // 方式2：URL scheme 调起 TrollStore
        let msg = installViaScheme(path)
        return ["ok": msg.ok, "method": msg.ok ? "trollstore://" : "none", "message": msg.message]
    }

    private func installViaScheme(_ path: String) -> (ok: Bool, message: String) {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "trollstore://install?url=file://\(encoded)") else {
            return (false, "无法构造 TrollStore 安装链接")
        }
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { done in
                ok = done
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 5)
        if ok {
            AppCatalog.invalidateCache()   // v2.9.135: 安装后失效应用缓存
            return (true, "已调起 TrollStore 安装 \(path)，请在 TrollStore 弹窗确认")
        }
        return (false, "调起 TrollStore 失败（未安装 TrollStore？）")
    }
}

final class AppUninstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.uninstall",
        summary: "卸载指定 bundle_id 的 App（trollstorehelper uninstall，TrollStore 环境）。卸载会删除该 App 数据容器，注意备份。",
        parameters: ["bundle_id": "要卸载的 App 的 bundle id（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("app.uninstall 需要 bundle_id 参数")
        }
        let im = InjectionManager.shared
        let helper = "/var/usr/bin/trollstorehelper"
        if FileManager.default.isExecutableFile(atPath: helper) {
            let (c, out) = im.spawnRoot(helper, args: ["uninstall", bid], timeout: 120)
            AuditLog.shared.log("app.uninstall", detail: "\(bid) c=\(c)")
            if c == 0 { AppCatalog.invalidateCache() }   // v2.9.135: 卸载后失效应用缓存
            return ["ok": c == 0, "bundle_id": bid, "output": out,
                    "message": c == 0 ? "已卸载 \(bid)" : "卸载失败: \(out)"]
        }
        return ["ok": false, "bundle_id": bid,
                "message": "trollstorehelper 不可用，请手动在 TrollStore 中卸载"]
    }
}
