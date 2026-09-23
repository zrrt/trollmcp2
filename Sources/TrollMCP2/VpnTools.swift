// VpnTool：MITM 抓包 VPN/代理控制工具（v3.3.0）
// 子命令：status / start / stop / cert / local_start / local_stop / logs

import Foundation

final class VpnTool: MCPTool {
    let definition = ToolDefinition(
        name: "vpn.capture",
        summary: "MITM packet capture (system-level). Use for: capture HTTPS plaintext of ANY app (custom network stacks, protobuf, self-built sockets included) — unlike network.capture which only hooks NSURLSession. Modes: VPN (start/stop, requires VpnTunnel appex installed, auto-routes system traffic) or local proxy (local_start/local_stop, requires user to set WiFi HTTP proxy to 127.0.0.1:18180 manually). First use: run cert to generate + install root CA (mobileconfig → Settings → install → enable Full Trust in Certificate Trust Settings), otherwise TLS handshake fails for apps. Limitations: QUIC/HTTP3 traffic not decrypted (app usually falls back to HTTP/2, then capturable); TLS-pinned apps will fail handshake; self-built raw-socket apps may lose network under VPN mode. Logs: Workspace/network_capture/mitm/*.txt (hex+TEXT per connection). Example: user says 'capture 小红书 with VPN' → vpn.capture command:start. REQUIRED PARAMS: none for status; cert generates CA profile.",
        parameters: [
            "command": "status / start / stop / cert / local_start / local_stop / logs"
        ],
        verified: false, category: "network", prerequisites: [
            "run cert first: generates Workspace/certs/TrollAgentCA.mobileconfig — user must install it in Settings and enable Full Trust (Settings→General→About→Certificate Trust Settings)",
            "start = VPN mode (NEVPNManager + VpnTunnel appex). If appex not installed/loadable, fall back to local_start + WiFi manual proxy",
            "after start, user uses the target app normally; logs appear in Workspace/network_capture/mitm/",
            "0 logs expected if app uses QUIC only (rare on cellular/proxy setups)"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let command = (params["command"] as? String) ?? "status"
        let vm = VpnManager.shared

        switch command {
        case "status":
            var status = "unknown"
            let raw = vm.vpnStatus.rawValue
            // NEVPNStatus: invalid=0, disconnecting=1, connecting=2, connected=3, reasserting=4, disconnecting=5
            switch raw {
            case 0: status = "invalid(not configured)"
            case 1: status = "disconnecting"
            case 2: status = "connecting"
            case 3: status = "connected"
            case 4: status = "reasserting"
            case 5: status = "disconnected"
            default: status = "raw\(raw)"
            }
            let mitmLogs = (try? FileManager.default.contentsOfDirectory(atPath: vm.mitmLogDir)) ?? []
            return [
                "mode": "vpn.capture",
                "vpn_status": status,
                "vpn_configured": vm.vpnConfigured,
                "local_proxy_running": vm.localProxyRunning,
                "proxy_port": Int(vm.proxyPort),
                "ca_installed_candidate": vm.caExists,
                "mitm_log_files": mitmLogs.count,
                "mitm_log_dir": vm.mitmLogDir,
                "hint": "first time: run cert, install mobileconfig + enable Full Trust; then start or local_start"
            ]

        case "start":
            var note = "VPN connecting (wait for system prompt)"
            vm.startVpn { err in
                if let e = err { note = "start failed: \(e)" }
            }
            return ["command": "start", "started": true, "note": note, "cert_reminder": "install+trust CA first if not done (vpn.capture command:cert)"]

        case "stop":
            vm.stopVpn()
            vm.stopLocalProxy()
            return ["command": "stop", "stopped": true]

        case "cert":
            guard let path = vm.generateMobileConfig() else {
                return ["command": "cert", "error": "mobileconfig generation failed", "hint": "check Workspace/certs/ca.pem exists"]
            }
            return ["command": "cert", "mobileconfig": path,
                    "steps": ["open the file with Files app to install profile",
                              "then Settings → General → About → Certificate Trust Settings → enable Full Trust for TrollAgent MITM CA",
                              "then run vpn.capture command:start (or local_start)"]]

        case "local_start":
            let ok = vm.startLocalProxy()
            return ["command": "local_start", "started": ok, "port": Int(vm.proxyPort),
                    "user_action": "set WiFi HTTP proxy to 127.0.0.1:18180 (Settings→WiFi→your network→Configure Proxy→Manual)",
                    "note": "apps honoring system proxy will be captured"]

        case "local_stop":
            vm.stopLocalProxy()
            return ["command": "local_stop", "stopped": true]

        case "logs":
            let dir = vm.mitmLogDir
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().reversed()
            let recent = Array(files.prefix(20))
            return ["command": "logs", "log_dir": dir, "recent_files": recent, "total": (try? FileManager.default.contentsOfDirectory(atPath: dir))?.count ?? 0]

        default:
            return ["error": "unknown command '\(command)'. Use status / start / stop / cert / local_start / local_stop / logs"]
        }
    }
}
