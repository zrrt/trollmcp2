// WifiProxyTool：AI 控制系统 Wi-Fi HTTP/HTTPS 代理（set/clear/status）
// 依据 2026-10-04 深度调研（RESEARCH_REPORT.md §4）重写：
//   ✗ 错误姿势：root 手改 /var/preferences/SystemConfiguration/preferences.plist
//     —— configd 持有运行时副本，手改会被忽略/覆盖；ifconfig en0 down/up 硬断 WiFi 违反"不断网"。
//   ✓ 正路：纯 SCPreferences session（Create → PathSetValue → CommitChanges → ApplyChanges），
//     macOS networksetup 同款 API；ApplyChanges 触发 configd 刷新运行时。
// 效果：系统 HTTP(S) 流量（URLSession/WebView）走代理 127.0.0.1:18180 被本地 MitmProxy
//   记录+转发 → 抓 HTTP(S) 不断网；UDP/QUIC/原生 socket 直连不经过代理 → 其余流量照常上网。
//   ExceptionsList 带 8790 AI 通道，防止控制通道被 MITM 劫持。
// 局限（如实）：只抓 HTTP(S)；抖音/微信音视频(QUIC/UDP/证书固定) 抓不到——那是 P1(修引擎转发闭环)的活。
import Foundation
import SystemConfiguration
import CFNetwork

final class WifiProxyExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "wifi",
        summary: "Control system Wi-Fi HTTP/HTTPS proxy via SCPreferences API (set/clear/status). AI-controlled system proxy for MITM capture — no manual Wi-Fi setup, HTTP(S) traffic captured while other traffic (video/UDP/QUIC/8790) stays direct online. Use for: point system HTTP(S) proxy at local MITM proxy (127.0.0.1:18180). Don't use for: QUIC/UDP/non-HTTP protocols (not proxied) or VPN full-tunnel capture (use vpn.capture). Example: wifi proxy set port:18180; wifi proxy clear; wifi proxy status. REQUIRED PARAMS: command=set/clear/status; set→port (Int, default 18180).",
        parameters: [
            "command": "Subcommand (required): set / clear / status",
            "port": "Proxy port for set (default 18180)"
        ],
        returns: [
            "ok": "true on success",
            "message": "human-readable result (service id, commit/apply status, runtime check)",
            "runtime": "CFNetworkCopySystemProxySettings runtime snapshot after operation (status)"
        ],
        verified: false, category: "net", uiSummary: "WiFi 系统代理控制（SCPreferences API，AI 一键开/关 HTTP(S) 代理指向本地 MITM）",
        requiresTrollStore: true,
        prerequisites: ["写系统代理配置经 SCPreferences（TrollStore no-sandbox 自动具备权限）", "HTTPS 解密需先安装并信任 TrollAgent MITM CA（设置页生成证书描述文件）", "与 VPN 全接管不要同时常开（避免双跳）"]
    )

    private let backupDir = "/var/mobile/Documents/Workspace/wifi_proxy_backup"
    /// 8790 AI 远程通道 + 本机 loopback 进例外，防被 MITM 劫持/代理死循环
    private let exceptions: [String] = ["localhost", "127.0.0.1", "192.168.31.108"]

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required: set/clear/status. Usage: wifi proxy set/clear/status")
        }
        AuditLog.shared.log("wifi", detail: command)
        switch command {
        case "status": return try status()
        case "set":
            let port = (params["port"] as? NSNumber)?.intValue ?? 18180
            return try setProxy(port: UInt16(port))
        case "clear": return try clearProxy()
        default:
            throw MCPError.invalidParams("unknown command: \(command). Usage: wifi proxy set/clear/status")
        }
    }

    // MARK: - 定位当前 Wi-Fi ServiceID（只读 plist 定位，不写文件）

    private func findWifiService() throws -> String {
        let path = "/var/preferences/SystemConfiguration/preferences.plist"
        guard FileManager.default.fileExists(atPath: path),
              let root = NSDictionary(contentsOfFile: path),
              let currentSet = root["CurrentSet"] as? String,
              let sets = root["Sets"] as? [String: Any],
              let set = sets[currentSet] as? [String: Any],
              let network = set["Network"] as? [String: Any] else {
            throw MCPError.classified("cannot locate CurrentSet/Network in preferences.plist", code: "ENV_MISSING", reason: "environment",
                                      nextStep: "ensure device Wi-Fi is on and TrollStore-installed (no-sandbox)")
        }
        for (sid, svc) in network {
            guard let svc = svc as? [String: Any],
                  let iface = svc["Interface"] as? [String: Any],
                  let type = iface["Type"] as? String, type == "IEEE80211" else { continue }
            return sid
        }
        throw MCPError.classified("no IEEE80211 (Wi-Fi) service found", code: "TARGET_MISSING", reason: "target",
                                  nextStep: "check Wi-Fi is enabled; only Wi-Fi interface proxy supported")
    }

    private func prefsSession() throws -> SCPreferences {
        guard let prefs = SCPreferencesCreate(nil, "trollagent" as CFString, nil) else {
            throw MCPError.classified("SCPreferencesCreate failed", code: "ENV_PERMISSION", reason: "environment",
                                      nextStep: "TrollStore no-sandbox required to open system preferences session")
        }
        return prefs
    }

    private func proxyPath(_ sid: String) -> CFString {
        return "/Network/Service/\(sid)/Proxies" as CFString
    }

    // MARK: - 子命令

    private func status() throws -> [String: Any] {
        let sid = try findWifiService()
        var runtime: [String: Any] = [:]
        if let sys = CFNetworkCopySystemProxySettings() as? [String: Any] { runtime = sys }
        let prefs = try prefsSession()
        let configured = SCPreferencesPathGetValue(prefs, proxyPath(sid)) as? [String: Any] ?? [:]
        let httpEnable = configured["HTTPEnable"] as? Int ?? 0
        let httpProxy = configured["HTTPProxy"] as? String ?? ""
        let httpPort = configured["HTTPPort"] as? Int ?? 0
        return ["ok": true,
                "message": "WiFi service \(sid): config HTTP=\(httpEnable == 1 ? "ON \(httpProxy):\(httpPort)" : "OFF") HTTPS=\(((configured["HTTPSEnable"] as? Int ?? 0) == 1) ? "ON" : "OFF"); runtime proxies: \(runtime.keys.sorted().prefix(8))",
                "service_id": sid, "configured": configured, "runtime": runtime]
    }

    private func setProxy(port: UInt16) throws -> [String: Any] {
        let sid = try findWifiService()
        let prefs = try prefsSession()
        let path = proxyPath(sid)

        // 备份原 Proxies（若存在）
        let fm = FileManager.default
        try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        if let old = SCPreferencesPathGetValue(prefs, path),
           let data = try? PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0) {
            try data.write(to: URL(fileURLWithPath: backupDir + "/proxies_backup.plist"))
        }

        // 写新代理（指向本地 MITM 代理 127.0.0.1:port）+ 例外清单（保护 8790/loopback）
        let proxies: [String: Any] = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": Int(port),
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": Int(port),
            "ExceptionsList": exceptions
        ]
        let okSet = SCPreferencesPathSetValue(prefs, path, proxies as CFPropertyList)
        let okCommit = SCPreferencesCommitChanges(prefs)
        let okApply = SCPreferencesApplyChanges(prefs)

        // 自校验：读运行时系统代理设置
        var runtime: [String: Any] = [:]
        if let sys = CFNetworkCopySystemProxySettings() as? [String: Any] { runtime = sys }
        let runtimeHTTPEnable = runtime["HTTPEnable"] as? Int ?? 0
        let effective = (okSet && okCommit && okApply) ? (runtimeHTTPEnable == 1 ? "ON(runtime verified)" : "set but runtime OFF") : "API FAILED"

        return ["ok": okSet && okCommit && okApply,
                "message": "WiFi proxy set on \(sid) → HTTP/HTTPS 127.0.0.1:\(port); ExceptionsList=\(exceptions); effect=\(effective). HTTPS capture needs MITM CA trusted. Other traffic (video/UDP/QUIC/8790) stays direct — no disconnection.",
                "service_id": sid, "commit": okCommit, "apply": okApply, "runtime": runtime]
    }

    private func clearProxy() throws -> [String: Any] {
        let sid = try findWifiService()
        let prefs = try prefsSession()
        let path = proxyPath(sid)

        var okSet = false
        let bak = backupDir + "/proxies_backup.plist"
        if FileManager.default.fileExists(atPath: bak),
           let data = try? Data(contentsOf: URL(fileURLWithPath: bak)),
           let restored = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            okSet = SCPreferencesPathSetValue(prefs, path, restored as CFPropertyList)
        } else {
            okSet = SCPreferencesPathRemoveValue(prefs, path)
        }
        let okCommit = SCPreferencesCommitChanges(prefs)
        let okApply = SCPreferencesApplyChanges(prefs)

        var runtime: [String: Any] = [:]
        if let sys = CFNetworkCopySystemProxySettings() as? [String: Any] { runtime = sys }
        let runtimeHTTPEnable = runtime["HTTPEnable"] as? Int ?? 0

        return ["ok": okSet && okCommit && okApply,
                "message": "WiFi proxy cleared on \(sid) (restored backup or removed); runtime HTTPEnable=\(runtimeHTTPEnable)",
                "service_id": sid, "commit": okCommit, "apply": okApply]
    }
}
