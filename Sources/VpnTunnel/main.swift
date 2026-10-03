// VpnTunnel：PacketTunnelProvider appex —— VPN 抓包模式
// 隧道建立后通过 NEProxySettings 把系统 HTTP/HTTPS 流量导向本地 MITM 代理(127.0.0.1:18180)，
// 代理解密并记录明文到 Workspace/network_capture/mitm/。
// 注：packetFlow 不转发（系统代理模式）；自建 socket 直连的 App 在 VPN 下会断网（已知边界）。

import Foundation
import NetworkExtension
import MitmCore

@objc public class TunnelProvider: NEPacketTunnelProvider {

    public override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[VpnTunnel] startTunnel begin")
        let started = MitmProxy.shared.start(port: 18180)
        NSLog("[VpnTunnel] mitm proxy started=\(started)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let proxy = NEProxySettings()
        let server = NEProxyServer(address: "127.0.0.1", port: 18180)
        proxy.httpServer = server
        proxy.httpsServer = server
        proxy.httpEnabled = true
        proxy.httpsEnabled = true
        proxy.autoProxyConfigurationEnabled = false
        settings.proxySettings = proxy

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.dnsSettings = dns

        // fix3cy9：纯代理模式——不设默认路由全接管（去掉 includedRoutes default）。
        // 系统只把 HTTP(S) 流量经 NEProxySettings 导进隧道（appex 内 MitmProxy 记录+转发），
        // 其余流量（视频流/局域网/8790 远程通道）走原网卡直连 → 不断网 + AI 通道在线。
        // 之前设 defaultRoute 全接管 + 引擎不转发 = 断网（与 Fuck 引擎同病）。
        let ipv4 = NEIPv4Settings(addresses: ["172.16.0.2"], subnetMasks: ["255.255.255.0"])
        settings.ipv4Settings = ipv4

        // 先完成隧道启动，再异步设置网络参数（系统代理生效）
        completionHandler(nil)
        setTunnelNetworkSettings(settings) { error in
            if let e = error {
                NSLog("[VpnTunnel] setTunnelNetworkSettings error: \(e.localizedDescription)")
            } else {
                NSLog("[VpnTunnel] tunnel ready, proxy on 127.0.0.1:18180")
            }
        }
    }

    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        MitmProxy.shared.stop()
        completionHandler()
    }

    public override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let status = MitmProxy.shared.isRunning ? "mitm:running:18180" : "mitm:stopped"
        completionHandler?(Data(status.utf8))
    }
}

// 进程入口占位（NE appex 由系统按 NSExtensionPrincipalClass 实例化本类）
let _ = TunnelProvider.self
