import Foundation
import UIKit

// v2.9.131：AI 安装/卸载 App——补全"下载 IPA → 安装 → 注入 → 启动 → 控制"全链路
// TrollStore 官方 trollstorehelper 静默安装优先（/var/usr/bin/trollstorehelper），
// 不存在或失败时降级 trollstore:// URL scheme 调起 TrollStore 确认安装

final class AppInstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.install",
        summary: "安装 IPA 到设备：TrollStore 官方 trollstorehelper 静默安装优先，不可用时自动调起 TrollStore 确认安装。ipa_path 传本地 ipa 绝对路径（工作区下载的 ipa 可直接用）。安装成功后 AI 可继续注入/启动/控制。",
        parameters: ["ipa_path": "本地 ipa 绝对路径（必填）"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["ipa_path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("app.install 需要 ipa_path 参数")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return ["ok": false, "error": "文件不存在: \(path)"]
        }
        let im = InjectionManager.shared
        // v2.9.273：trollstorehelper 在 TrollStore.app bundle 内（TrollStore 源码 TSUtil.m
        // rootHelperPath = NSBundle.mainBundle.bundlePath/trollstorehelper），不在 /var/usr/bin！
        let tsPath = AppCatalog.list().first { $0.bundleId == "com.opa334.TrollStore" }?.path ?? ""
        var helper = tsPath.isEmpty ? "/var/usr/bin/trollstorehelper" : tsPath + "/trollstorehelper"
        var helperExist = FileManager.default.fileExists(atPath: helper)
        if !helperExist, !tsPath.isEmpty {
            let variants = [tsPath + "/trollstorehelper",
                            tsPath + "/TrollStore.app/trollstorehelper",
                            (tsPath as NSString).deletingLastPathComponent + "/trollstorehelper"]
            for v in variants where FileManager.default.fileExists(atPath: v) { helper = v; helperExist = true; break }
        }

        // v2.9.274/275：加 force——TrollStore installApp 对"已装但非 TrollStore App"（无
        // TS_ACTIVE_MARKER 的 App Store 版）无 force 直接返回 171 拒绝覆盖（实测小红书）
        // ⚠️ 关键：trollstorehelper 源码用 args.lastObject 取 ipaPath，force 必须放在
        //  path 之前！否则 ipaPath="force" 装空气（274 首版踩坑，275 修复参数顺序）
        // v2.9.279：用 installd 系统方法——custom 数据容器安装注册为 System 类型
        // （registerAsUser = path.hasPrefix("/var/containers")，数据容器不满足），
        // iOS 16 上 LaunchServices 不生效、图标不出现。installd 装到标准 bundle 容器
        // 注册为 User，图标正常显示。
        let (c, out) = im.spawnRoot(helper, args: ["install", "installd", "force", path], timeout: 240)
        // v2.9.282：TrollStore 源码明确 184=app has additional encrypted binaries（non-fatal，
        // 子 framework 加密由系统解密，安装正常可用）；182=需开发者模式（non-fatal）。
        // 之前把 184 当失败误报"安装失败"，实际安装已完成。
        let installOK = (c == 0 || c == 184 || c == 182)
        if installOK {
            AuditLog.shared.log("app.install", detail: "\(path) → \(helper) c=\(c)")
            AppCatalog.invalidateCache()   // v2.9.135: 安装后失效应用缓存
            // v2.9.283：refresh-all 会删 IconsCache + rebuild + killall backboardd
            // （TrollStore 源码注释承认会搞乱主屏/重置注册，用户实测"巨魔 app 全打不开"）。
            // 改用 refresh 命令——安全重注册全部 TrollStore app，不 rebuild 不杀 backboardd。
            _ = im.spawnRoot(helper, args: ["refresh"], timeout: 90)
            return ["ok": true, "method": "trollstorehelper", "output": out,
                    "message": c == 0 ? "已静默安装 \(path)" : "已安装（\(c)：\(c == 184 ? "子二进制加密，系统解密，非致命" : "需开发者模式")）\(path)"]
        }
        // 失败降级 URL scheme（记录 spawn 真实错误，便于远程诊断）
        let msg = installViaScheme(path)
        let cOut = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["ok": msg.ok, "method": msg.ok ? "trollstore://" : "trollstorehelper_failed",
                "output": cOut.isEmpty ? "(spawn 退出码 \(c)，helper=\(helper) exist=\(helperExist))" : cOut,
                "message": "trollstorehelper 失败（exit=\(c)）。\(msg.message)"]
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
        parameters: ["bundle_id": "要卸载的 App 的 bundle id（必填）"],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("app.uninstall 需要 bundle_id 参数")
        }
        let im = InjectionManager.shared
        // v2.9.274：与 app.install 一致的 helper 定位（TrollStore.app bundle 内）
        let tsPath = AppCatalog.list().first { $0.bundleId == "com.opa334.TrollStore" }?.path ?? ""
        let helper = tsPath.isEmpty ? "/var/usr/bin/trollstorehelper" : tsPath + "/trollstorehelper"
        // v2.9.276：custom 卸载——系统方法(LSApplicationWorkspace)对 App Store 版
        // 返回 0 但实际不删 bundle（实测小红书 7DA17D81 残留，导致双注册）。
        // v2.9.278：卸载前先记录旧 bundle 路径——卸载后 LaunchServices 已注销查不到，
        // 但磁盘残留文件还在，refresh-all 会把它扫回注册（277 的"卸载后再查"漏删）。
        // 所以卸载成功后无条件按记录路径 uninstall-path custom 硬删。
        let oldPath = AppCatalog.list().first { $0.bundleId == bid }?.path
        let (c, out) = im.spawnRoot(helper, args: ["uninstall", "custom", bid], timeout: 120)
        AuditLog.shared.log("app.uninstall", detail: "\(bid) c=\(c)")
        if c == 0 {
            if let p = oldPath, FileManager.default.fileExists(atPath: p) {
                let (c2, out2) = im.spawnRoot(helper, args: ["uninstall-path", "custom", p], timeout: 90)
                AuditLog.shared.log("app.uninstall-path", detail: "\(p) c=\(c2) \(String(out2.prefix(60)))")
            }
            // v2.9.283：refresh-all 会搞乱巨魔 app 注册（用户实测"全部打不开"），改 refresh
            _ = im.spawnRoot(helper, args: ["refresh"], timeout: 90)
            AppCatalog.invalidateCache()
        }
        return ["ok": c == 0, "bundle_id": bid, "output": out,
                "message": c == 0 ? "已卸载 \(bid)" : "卸载失败: \(out)"]
    }
}
