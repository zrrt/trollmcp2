// WifiProxyTool：WiFi 系统代理查询（AI 用，status 为主）
// 重要更正（2026-10-04 编译实证）：SCPreferencesCreate/Commit/Apply 在 iOS SDK 标注 unavailable
//   —— iOS 没有"程序化改 WiFi 代理"的官方 API（只能手动去设置填，或 VPN NEProxySettings / MDM）。
//   因此本工具仅提供：
//   - status：读系统运行时代理（CFNetworkCopySystemProxySettings，iOS 可用）+ plist 配置（只读）
//   - set/clear：降级为"手改 preferences.plist"（root 可写；configd 可能覆盖，标注不可靠，仅应急用）
// 主线抓包方案 = vpn.capture（P1 hev 全接管转发），本工具只做辅助诊断。
import Foundation
import SystemConfiguration
import CFNetwork

final class WifiProxyExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "wifi",
        summary: "Read system proxy state (status) or emergency set/clear via direct plist edit (set/clear). iOS has NO official API to programmatically set Wi-Fi proxy (SCPreferences is macOS-only) — VPN capture (vpn.capture) is the correct path. Use for: checking whether the device is behind an HTTP(S) proxy (status), emergency proxy toggling. Example: wifi proxy status; wifi proxy set port:18180; wifi proxy clear. REQUIRED PARAMS: command=set/clear/status.",
        parameters: [
            "command": "Subcommand (required): set / clear / status",
            "port": "Proxy port for set (default 18180)"
        ],
        returns: [
            "ok": "true on success",
            "message": "human-readable result",
            "runtime": "CFNetworkCopySystemProxySettings runtime snapshot"
        ],
        verified: false, category: "net", uiSummary: "WiFi 系统代理查询/应急开关（iOS 无官方代理设置 API，主用 status 诊断）",
        requiresTrollStore: true,
        prerequisites: ["主线抓包请用 vpn.capture（P1 hev 转发，不断网）", "set/clear 为手改 plist，configd 可能覆盖，仅应急"]
    )

    private let plistPath = "/var/preferences/SystemConfiguration/preferences.plist"
    private let backupDir = "/var/mobile/Documents/Workspace/wifi_proxy_backup"

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required: set/clear/status")
        }
        AuditLog.shared.log("wifi", detail: command)
        switch command {
        case "status": return try status()
        case "set":
            let port = (params["port"] as? NSNumber)?.intValue ?? 18180
            return try setProxy(port: UInt16(port))
        case "clear": return try clearProxy()
        default:
            throw MCPError.invalidParams("unknown command: \(command)")
        }
    }

    private func runtimeProxy() -> [String: Any] {
        if let sys = CFNetworkCopySystemProxySettings() as? [String: Any] { return sys }
        return [:]
    }

    private func wifiService() -> (setID: String, sid: String, svc: NSMutableDictionary)? {
        guard FileManager.default.fileExists(atPath: plistPath),
              let root = NSDictionary(contentsOfFile: plistPath),
              let currentSet = root["CurrentSet"] as? String,
              let sets = root["Sets"] as? [String: Any],
              let set = sets[currentSet] as? [String: Any],
              let network = set["Network"] as? [String: Any] else { return nil }
        for (key, value) in network {
            guard let sid = key as? String,
                  let svc = value as? [String: Any],
                  let iface = svc["Interface"] as? [String: Any],
                  let type = iface["Type"] as? String, type == "IEEE80211" else { continue }
            return (currentSet, sid, NSMutableDictionary(dictionary: svc))
        }
        return nil
    }

    private func status() throws -> [String: Any] {
        let runtime = runtimeProxy()
        let httpEnable = runtime["HTTPEnable"] as? Int ?? 0
        let httpProxy = runtime["HTTPProxy"] as? String ?? ""
        let httpPort = runtime["HTTPPort"] as? Int ?? 0
        let configured = wifiService().map { $0.svc["Proxies"] } ?? nil
        return ["ok": true,
                "message": "runtime proxy HTTP=\(httpEnable == 1 ? "ON \(httpProxy):\(httpPort)" : "OFF") HTTPS=\(((runtime["HTTPSEnable"] as? Int ?? 0) == 1) ? "ON" : "OFF"); configured=\(configured ?? "none")",
                "runtime": runtime, "configured": configured]
    }

    /// 应急：手改 preferences.plist 的 Proxies（iOS 无官方 API；configd 运行时副本可能覆盖，标注不可靠）
    private func setProxy(port: UInt16) throws -> [String: Any] {
        guard let (_, sid, svc) = wifiService() else {
            throw MCPError.classified("no Wi-Fi service found in preferences.plist", code: "TARGET_MISSING", reason: "target",
                                      nextStep: "check Wi-Fi is enabled; prefer vpn.capture instead of manual proxy edit")
        }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let existing = svc["Proxies"] as? NSDictionary
        if let e = existing, let data = try? PropertyListSerialization.data(fromPropertyList: e, format: .binary, options: 0) {
            try? data.write(to: URL(fileURLWithPath: backupDir + "/proxies_backup.plist"))
        }
        let proxies = NSMutableDictionary()
        proxies["HTTPEnable"] = 1
        proxies["HTTPProxy"] = "127.0.0.1"
        proxies["HTTPPort"] = Int(port)
        proxies["HTTPSEnable"] = 1
        proxies["HTTPSProxy"] = "127.0.0.1"
        proxies["HTTPSPort"] = Int(port)
        svc["Proxies"] = proxies

        guard let root = NSMutableDictionary(contentsOfFile: plistPath),
              let currentSet = root["CurrentSet"] as? String,
              let sets = root["Sets"] as? NSMutableDictionary,
              let set = sets[currentSet] as? NSMutableDictionary,
              let network = set["Network"] as? NSMutableDictionary else {
            throw MCPError.failed("cannot re-open plist for write")
        }
        network[sid] = svc
        let outData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try outData.write(to: URL(fileURLWithPath: plistPath))
        let runtime = runtimeProxy()
        return ["ok": true,
                "message": "emergency plist edit done on \(sid) → HTTP/HTTPS 127.0.0.1:\(port); NOTE: iOS has no official proxy-set API, configd may override — prefer vpn.capture (P1). runtime HTTPEnable=\(runtime["HTTPEnable"] as? Int ?? 0)",
                "service_id": sid, "runtime": runtime]
    }

    private func clearProxy() throws -> [String: Any] {
        guard let (_, sid, svc) = wifiService() else {
            throw MCPError.classified("no Wi-Fi service found", code: "TARGET_MISSING", reason: "target", nextStep: "check Wi-Fi")
        }
        let bak = backupDir + "/proxies_backup.plist"
        if FileManager.default.fileExists(atPath: bak),
           let data = try? Data(contentsOf: URL(fileURLWithPath: bak)),
           let restored = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            svc["Proxies"] = restored
        } else {
            svc.removeObject(forKey: "Proxies")
        }
        guard let root = NSMutableDictionary(contentsOfFile: plistPath),
              let currentSet = root["CurrentSet"] as? String,
              let sets = root["Sets"] as? NSMutableDictionary,
              let set = sets[currentSet] as? NSMutableDictionary,
              let network = set["Network"] as? NSMutableDictionary else {
            throw MCPError.failed("cannot re-open plist for write")
        }
        network[sid] = svc
        let outData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try outData.write(to: URL(fileURLWithPath: plistPath))
        let runtime = runtimeProxy()
        return ["ok": true,
                "message": "emergency plist clear done on \(sid); runtime HTTPEnable=\(runtime["HTTPEnable"] as? Int ?? 0)",
                "service_id": sid]
    }
}
