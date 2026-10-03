// VpnTunnel：PacketTunnelProvider appex —— 全量抓包隧道（P1：hev 转发内核）
// 链路（抄 socksguard/Tun2SocksKit 已验证先例）：
//   全接管(IPv4+IPv6 default) → packetFlow 全部进 TUN → hev-socks5-tunnel(lwip 栈，
//   终止 TCP/UDP，连本机 SOCKS5) → Socks5Server(127.0.0.1:19080) 出真实网络+记录
//   → hev 合成响应 → writePackets 写回隧道 → 不断网 + 全流量抓包(原始字节流 hexlog)。
// 依据深度调研（RESEARCH_REPORT.md）："全接管+引擎内双向转发"是 NEKit/Potatso/Leaf/
//   socksguard 标准架构；断网根因是只收不转，hev 内核补齐转发闭环。
// 注意：TrollStore 首次开 VPN 会弹一次"允许"；system proxy 与 VPN 不要同时开。
import Foundation
import NetworkExtension
import MitmCore
import Tun2SocksKit
import Tun2SocksKitC

@objc public class TunnelProvider: NEPacketTunnelProvider {

    private var stopping = false
    private let socks5Port: UInt16 = 19080

    public override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[VpnTunnel] startTunnel begin (P1 hev forward engine)")
        // 1) 起本机 SOCKS5 server（hev 的出口：出网 + 记录）
        let s5 = Socks5Server.shared.start(port: socks5Port)
        NSLog("[VpnTunnel] socks5 server started=\(s5) on \(socks5Port)")

        // 2) 全接管网络设置（抄 socksguard：IPv4+IPv6 default，防止泄漏）
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fc00::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = []
        settings.ipv6Settings = ipv6
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.mtu = 9000

        // 3) 隧道设置生效后启动 hev 内核（阻塞线程，quit 或致命错误才返回）
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let e = error {
                NSLog("[VpnTunnel] setTunnelNetworkSettings error: \(e.localizedDescription)")
                completionHandler(e)
                return
            }
            NSLog("[VpnTunnel] network settings applied, starting hev core")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                // 等 utun fd 出现（socksguard 经验：settings 生效后 fd 才在本进程出现）
                var fd: Int32?
                for _ in 1...10 {
                    fd = self.findUtunFd()
                    if fd != nil { break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                NSLog("[VpnTunnel] utun fd \(fd ?? -1)")
                let yaml = Self.makeConfig(port: Int(self.socks5Port),
                                           logPath: "/var/mobile/Documents/Workspace/logs/hev.log")
                self.stopping = false
                let code = Socks5Tunnel.run(withConfig: .string(content: yaml))
                NSLog("[VpnTunnel] tunnel core exited code \(code)")
                if !self.stopping {
                    self.cancelTunnelWithError(NSError(domain: "TrollAgent.VpnTunnel", code: Int(code),
                                                       userInfo: [NSLocalizedDescriptionKey: "tunnel core exited"]))
                }
            }
            completionHandler(nil)
        }
    }

    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[VpnTunnel] stopTunnel reason \(reason.rawValue)")
        stopping = true
        Socks5Tunnel.quit()
        Socks5Server.shared.stop()
        completionHandler()
    }

    public override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let cmd = String(data: messageData, encoding: .utf8) ?? "stats"
        if cmd == "status" {
            let s5 = Socks5Server.shared.isRunning ? "socks5:running:\(Socks5Server.shared.port)" : "socks5:stopped"
            let stats = Socks5Tunnel.stats
            completionHandler?(Data("\(s5);up=\(stats.up.bytes)B;down=\(stats.down.bytes)B".utf8))
            return
        }
        completionHandler?(Data("unknown cmd".utf8))
    }

    public override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    public override func wake() {}

    // MARK: - utun fd 探测（Tun2SocksKit 内部同款，这里用于启动诊断日志）

    private func findUtunFd() -> Int32? {
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM { continue }
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, CTLIOCGINFO, &ctlInfo)
                if ret != 0 { continue }
            }
            if addr.sc_id == ctlInfo.ctl_id { return fd }
        }
        return nil
    }

    // MARK: - hev-socks5-tunnel 配置（低内存 profile，抄 socksguard）

    private static func makeConfig(port: Int, logPath: String) -> String {
        return """
        tunnel:
          mtu: 9000
          ipv4: 198.18.0.1
          ipv6: 'fc00::1'

        socks5:
          address: 127.0.0.1
          port: \(port)
          udp: 'udp'

        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          max-session-count: 768
          connect-timeout: 5000
          tcp-read-write-timeout: 60000
          udp-read-write-timeout: 60000
          log-file: \(logPath)
          log-level: debug
          limit-nofile: 65535
        """
    }
}

// 进程入口占位（NE appex 由系统按 NSExtensionPrincipalClass 实例化本类）
let _ = TunnelProvider.self
