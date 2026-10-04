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
import CHev

// fix3cy25b：Foundation 的 Swift 模块不导出 NSExtensionMain（ObjC 头私有），
//   用 @_silgen_name 绑定 C 符号 _NSExtensionMain（Foundation 库导出）。
@_silgen_name("_NSExtensionMain")
public func NSExtensionMain() -> Int32

@_cdecl("main")
public func main() -> Int32 {
    return NSExtensionMain()
}

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
        // fix3cy19：WiFi 子网排除——保 8790 远程 AI 通道 + 局域网设备（调研 RESEARCH_REPORT §6.3-⑧）
        //   （全接管若连本机 LAN 也吞，AI 无法通过 8790 连接分析）
        let (lanNet, lanMask, lanIPv6) = Self.localSubnet()
        var excl4: [NEIPv4Route] = []
        if let n = lanNet, let m = lanMask {
            excl4.append(NEIPv4Route(destinationAddress: n, subnetMask: m))
            NSLog("[VpnTunnel] excluded LAN \(n)/\(m) (keep 8790 online)")
        }
        ipv4.excludedRoutes = excl4
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fc00::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        var excl6: [NEIPv6Route] = []
        if let i6 = lanIPv6 {
            excl6.append(NEIPv6Route(destinationAddress: i6, networkPrefixLength: NSNumber(value: 64)))
        }
        excl6.append(NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: NSNumber(value: 10)))  // link-local 排除
        ipv6.excludedRoutes = excl6
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
                // 直接调 hev 内核（CHev 桥接；config 用字符串内存版，避免写文件）
                let bytes = Array(yaml.utf8)
                let code = bytes.withUnsafeBufferPointer { buf -> Int32 in
                    hev_socks5_tunnel_main_from_str(buf.baseAddress, UInt32(bytes.count), fd ?? -1)
                }
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
        hev_socks5_tunnel_quit()
        Socks5Server.shared.stop()
        completionHandler()
    }

    public override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let cmd = String(data: messageData, encoding: .utf8) ?? "stats"
        if cmd == "status" {
            let s5 = Socks5Server.shared.isRunning ? "socks5:running:\(Socks5Server.shared.port)" : "socks5:stopped"
            var txp: UInt = 0, txb: UInt = 0, rxp: UInt = 0, rxb: UInt = 0
            hev_socks5_tunnel_stats(&txp, &txb, &rxp, &rxb)
            completionHandler?(Data("\(s5);up=\(txb)B;down=\(rxb)B".utf8))
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

    // MARK: - 本机 LAN 子网（getifaddrs 读 en0，excludedRoutes 保 8790 用）

    private static func localSubnet() -> (net: String?, mask: String?, ip6: String?) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (nil, nil, nil) }
        defer { freeifaddrs(first) }
        var ip: String?, mask: String?, ip6: String?
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let c = cur {
            let family = c.pointee.ifa_addr.pointee.sa_family
            let name = String(cString: c.pointee.ifa_name)
            if name == "en0" {
                if family == sa_family_t(AF_INET) {
                    var addr = c.pointee.ifa_addr.pointee
                    var nm = c.pointee.ifa_netmask.pointee
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    var nmh = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                       getnameinfo(&nm, socklen_t(MemoryLayout<sockaddr_in>.size), &nmh, socklen_t(nmh.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ipStr = String(cString: host)
                        let maskStr = String(cString: nmh)
                        // 网络地址 = ip & mask
                        var a = in_addr(); var m = in_addr()
                        inet_pton(AF_INET, ipStr, &a)
                        inet_pton(AF_INET, maskStr, &m)
                        var net = in_addr(s_addr: a.s_addr & m.s_addr)
                        var nb = [CChar](repeating: 0, count: 16)
                        inet_ntop(AF_INET, &net, &nb, socklen_t(nb.count))
                        ip = String(cString: nb)
                        mask = maskStr
                    }
                } else if family == sa_family_t(AF_INET6) {
                    var addr = c.pointee.ifa_addr.pointee
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        var s = String(cString: host)
                        if let idx = s.firstIndex(of: "%") { s = String(s[..<idx]) }
                        ip6 = s
                    }
                }
            }
            cur = c.pointee.ifa_next
        }
        return (ip, mask, ip6)
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
