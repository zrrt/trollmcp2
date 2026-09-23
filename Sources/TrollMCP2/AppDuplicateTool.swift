import Foundation

// v2.9.136：改包名双开工具
// 原理：复制目标 App bundle → 改 Info.plist 的 CFBundleIdentifier / 显示名 →
//       删 _CodeSignature (交给 TrollStore 重签）→ 打包 ipa → trollstorehelper 静默安装。
// 双开后的 App 拥有全新数据容器 (登录态/缓存独立），与 TrollFools / 注入完全兼容。
// 限制：仅对"未加密"的侧载 App 有效 (App Store 加密 App 复制后主二进制加密，装不上）。

final class AppDuplicateTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.duplicate",
        summary: "Clone an app to create a parallel copy (two versions side by side). Use for: run two accounts at once, test without affecting original. Don't use for: just install app (use app.install), duplicate data (use backup.restore). Note: doesn't work on encrypted apps (decrypt first). Example: user says 'install two WeChat copies, log into both' → clone app.",
        parameters: [
            "bundle_id": "Source App bundle ID to clone (required)",
            "new_name": "New display name (optional)",
            "new_bundle_id": "New bundle ID (optional, auto)"
        ], verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("app.duplicate requires bundle_id param")
        }
        guard let app = AppCatalog.find(bid) else {
            return ["ok": false, "error": "App does not exist: \(bid)", "next_step": "use injection.list to find the correct bundle_id"]
        }

        // 高危护栏：敏感 App 提醒 (不阻断，AI 需看到风险）
        let sensitive = InjectionManager.isSensitive(bid)

        let fm = FileManager.default
        let im = InjectionManager.shared
        let workspace = Workspace.root
        let dupRoot = workspace.appendingPathComponent("duplicates").path
        try? fm.createDirectory(atPath: dupRoot, withIntermediateDirectories: true)

        // 1. 目标 bundle id：默认 原ID.dup，冲突则追加序号
        var newBid = (params["new_bundle_id"] as? String) ?? (bid + ".dup")
        if AppCatalog.find(newBid) != nil {
            var i = 2
            while AppCatalog.find(newBid + "\(i)") != nil { i += 1 }
            newBid = newBid + "\(i)"
        }

        // 2. 显示名
        var newName = (params["new_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if newName.isEmpty { newName = (app.name.isEmpty ? bid : app.name) + " Clone" }

        // 3. 复制 bundle (root cp -a，源在系统容器只读）
        let appDirName = (app.path as NSString).lastPathComponent
        let destApp = dupRoot + "/" + appDirName.replacingOccurrences(of: ".app", with: ".dup.app")
        try? fm.removeItem(atPath: destApp)
        let (c, out) = im.spawnRoot("/bin/cp", args: ["-a", app.path, destApp], timeout: 180)
        guard c == 0 else {
            return ["ok": false, "error": "copy App failed: \(out.prefix(200))",
                    "next_step": "check workspace disk space and App container read permission (AppDataContainers)"]
        }

        // 4. 删除旧签名 (TrollStore 安装时会重新签名；保留旧签名可能导致安装后无法启动）
        let codeSign = destApp + "/_CodeSignature"
        if fm.fileExists(atPath: codeSign) {
            _ = im.spawnRoot("/bin/rm", args: ["-rf", codeSign])
        }
        let codeResources = destApp + "/CodeResources"
        if fm.fileExists(atPath: codeResources) {
            _ = im.spawnRoot("/bin/rm", args: ["-rf", codeResources])
        }

        // 5. 改 Info.plist (复制件在工作区可写，直接 Foundation 读写）
        let plistPath = destApp + "/Info.plist"
        guard let plist = NSMutableDictionary(contentsOfFile: plistPath) else {
            return ["ok": false, "error": "failed to read copy Info.plist", "next_step": "App Info.plist cannot be parsed (may be encrypted/corrupted)"]
        }
        plist["CFBundleIdentifier"] = newBid
        plist["CFBundleDisplayName"] = newName
        if plist["CFBundleName"] != nil { plist["CFBundleName"] = newName }
        // 双开副本不参与原版更新检测；移除可能的自动更新 URL
        plist.removeObject(forKey: "CFBundleVersion")
        guard plist.write(toFile: plistPath, atomically: true) else {
            return ["ok": false, "error": "failed to write copy Info.plist", "next_step": "check workspace write permission"]
        }

        // 6. 打包 ipa (Payload/App.app 结构 + 纯 Swift Zip）
        let ipaName = newBid + "_duplicate.ipa"
        let ipaPath = dupRoot + "/" + ipaName
        let payloadRoot = dupRoot + "/Payload-" + newBid
        try? fm.removeItem(atPath: payloadRoot)
        try? fm.createDirectory(atPath: payloadRoot + "/Payload", withIntermediateDirectories: true)
        let payloadApp = payloadRoot + "/Payload/" + ((destApp as NSString).lastPathComponent)
        try? fm.removeItem(atPath: payloadApp)
        let (c2, out2) = im.spawnRoot("/bin/cp", args: ["-a", destApp, payloadApp], timeout: 180)
        guard c2 == 0 else {
            return ["ok": false, "error": "assemble Payload failed: \(out2.prefix(200))",
                    "next_step": "workspace disk space insufficient or permission error"]
        }
        try? fm.removeItem(atPath: ipaPath)
        guard ZipStorer.createZip(at: ipaPath, fromDirectory: payloadRoot) else {
            return ["ok": false, "error": "packaging ipa failed", "next_step": "ZipStorer write error, check disk space"]
        }
        try? fm.removeItem(atPath: payloadRoot)
        try? fm.removeItem(atPath: destApp)

        // 7. TrollStore 静默安装 (自动重签）
        let helper = "/var/usr/bin/trollstorehelper"
        if fm.isExecutableFile(atPath: helper) {
            let (c3, out3) = im.spawnRoot(helper, args: ["install", ipaPath], timeout: 180)
            if c3 == 0 {
                AppCatalog.invalidateCache()
                return ["ok": true, "new_bundle_id": newBid, "new_name": newName,
                        "ipa_path": ipaPath, "method": "trollstorehelper",
                        "sensitive_warning": sensitive ? "target App is sensitive (Xiaohongshu/Alipay/banking etc.), clone runs independently, confirm compliant use." : "",
                        "message": "clone OK: \(newName) (\(newBid)), installed, independent data container"]
            }
            return ["ok": false, "error": "trollstorehelper install failed: \(out3.prefix(200))",
                    "ipa_path": ipaPath,
                    "next_step": "ipa generated at \(ipaPath), install manually via TrollStore (auto re-sign)"]
        }
        return ["ok": false, "error": "trollstorehelper unavailable",
                "ipa_path": ipaPath,
                "next_step": "ipa generated at \(ipaPath), open and install manually in TrollStore"]
    }
}
