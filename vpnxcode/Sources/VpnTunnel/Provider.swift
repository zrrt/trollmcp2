// VpnTunnel Provider（Xcode app-extension 形态，P1 Step B：hev 转发内核）
// 链路（抄 socksguard/Tun2SocksKit 已验证先例）：
//   全接管(IPv4+IPv6 default) → packetFlow 全进 TUN → hev-socks5-tunnel(lwip 栈，
//   终止 TCP/UDP，连本机 SOCKS5) → Socks5Server(127.0.0.1:19080) 出真实网络+hexlog 记录
//   → hev 合成响应 → writePackets 写回隧道 → 不断网 + 全流量抓包(原始字节流 hexlog)。
// Xcode 标准扩展形态：Xcode 自动 -e _NSExtensionMain 布线（本文件无 main、无 dlsym），
//   已验证 NE 能拉起（Step A 里程碑）。Step B 在此形态上集成 hev 转发内核 + Socks5Server。
//   CHev 函数/类型经 Bridging.h 暴露；Socks5Server 来自 Sources/Socks5Server/。
// 注意：TrollStore 首次开 VPN 会弹一次"允许"；system proxy 与 VPN 不要同时开。
import Foundation
import Darwin
import NetworkExtension

// Step B: 日志写 AppGroup 共享容器 (group.com.ai.iosxcode)——appex 无 no-sandbox，
//   主 App 容器 /var/mobile/Documents/Workspace 写不进；AppGroup 主 App 与 appex 都能读。
private let appGroupID = "group.com.ai.iosxcode"
func appGroupContainer() -> String? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?.path
}
private func appexLog(_ msg: String) {
    let ts = String(Int(Date().timeIntervalSince1970))
    let line = "[\(ts)] \(msg)\n"
    let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
    var paths: [String] = []
    if let d = docs { paths.append(d + "/appex.log") }
    if let g = appGroupContainer() { paths.append(g + "/logs/appex.log") }
    for p in paths {
        // fix3cy30: 此前 appex.log 目标目录 AppGroup/logs/ 从未创建 → fopen 静默失败，
        //   "startTunnel 没写日志"被误判为 appex 没被拉起（实际可能跑了但日志全丢）。先建目录再写。
        let dir = (p as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let h = fopen(p, "a") { fputs(line, h); fclose(h) }
    }
}

@objc public class TunnelProvider: NEPacketTunnelProvider {

    private var stopping = false
    private let socks5Port: UInt16 = 19080

    // fix3cy30: 在类 init 打日志，区分"NE 压根没拉起 appex"(无 init 日志) vs "拉起但 startTunnel 前崩/没被调"。
    public override init() {
        super.init()
        appexLog("TunnelProvider init")
        NSLog("[VpnTunnel] TunnelProvider init")
    }

    public override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        appexLog("startTunnel begin (P1 Step B hev forward engine)")
        NSLog("[VpnTunnel] startTunnel begin (P1 Step B hev forward engine)")
        // 1) 起本机 SOCKS5 server（hev 的出口：出网 + hexlog 记录）——AppGroup 容器日志
        let s5 = Socks5Server.shared.start(port: socks5Port)
        appexLog("socks5 server started=\(s5) port=\(socks5Port)")
        NSLog("[VpnTunnel] socks5 server started=\(s5) on \(socks5Port) logDir=\(Socks5Server.shared.logDir)")
        // fix3cy33: 开一条结构化抓包任务(capture_task)
        CaptureDB.shared.beginTask(ruleName: "full")
        // fix3cy35: 回环自检——确认 appex 能否连到自己的 Socks5Server(定位 hev 到不了本地代理)
        loopbackSelfTest()

        // 2) 全接管网络设置（抄 socksguard：IPv4+IPv6 default，防止泄漏）
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // WiFi 子网排除——保 8790 远程 AI 通道 + 局域网设备
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
        // fix3cy30: MTU 9000 疑似被 iOS NE 拒绝（NE 隧道 MTU 上限 1500），
        //   setTunnelNetworkSettings 报错 → 隧道起不来（症状=一直 .disconnected）。降到标准 1500。
        settings.mtu = 1500

        // 3) 隧道设置生效后启动 hev 内核（阻塞线程，quit 或致命错误才返回）
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let e = error {
                NSLog("[VpnTunnel] setTunnelNetworkSettings error: \(e.localizedDescription)")
                appexLog("setTunnelNetworkSettings ERROR: \(e.localizedDescription)")
                completionHandler(e)
                return
            }
            appexLog("network settings applied OK, starting hev core")
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
                appexLog("utun fd \(fd ?? -1)")
                let hevLog = (appGroupContainer() ?? "/tmp") + "/logs/hev.log"
                // fix3cy36: hev 连本机 LAN IP(被 NE exclude、不进隧道)——127.0.0.1 会被 NE include default 劫持进 utun 死循环
                let lanIP = Self.lanIPv4Address() ?? "127.0.0.1"
                let yaml = Self.makeConfig(socks5Address: lanIP, port: Int(self.socks5Port), logPath: hevLog)
                appexLog("hev socks5 target=\(lanIP):\(self.socks5Port)")
                self.stopping = false
                // 直接调 hev 内核（CHev 桥接；config 用字符串内存版，避免写文件）
                let bytes = Array(yaml.utf8)
                let code = bytes.withUnsafeBufferPointer { buf -> Int32 in
                    hev_socks5_tunnel_main_from_str(buf.baseAddress, UInt32(bytes.count), fd ?? -1)
                }
                NSLog("[VpnTunnel] tunnel core exited code \(code)")
                appexLog("tunnel core exited code \(code) stopping=\(self.stopping)")
                if !self.stopping {
                    self.cancelTunnelWithError(NSError(domain: "TrollAgent.VpnTunnel", code: Int(code),
                                                       userInfo: [NSLocalizedDescriptionKey: "tunnel core exited"]))
                }
            }
            completionHandler(nil)
            appexLog("tunnel setup complete (completionHandler nil)")
        }
    }

    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[VpnTunnel] stopTunnel reason \(reason.rawValue)")
        appexLog("stopTunnel reason=\(reason.rawValue)")
        stopping = true
        hev_socks5_tunnel_quit()
        Socks5Server.shared.stop()
        // fix3cy34: VPN 停止时导出 HAR（AI/主 App 消费路径），失败不影响停止
        let har = CaptureDB.shared.exportHAR()
        appexLog("har exported to \(har)")
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

    // MARK: - 回环自检（fix3cy35）
    //   现象：hev 疯狂连 127.0.0.1:19080 但 Socks5Server.accept 全程空 → hev 到不了本地代理。
    //   自检直接连 127.0.0.1:19080 + SOCKS5 握手，一锤定音：
    //     连上+握手OK = 回环/accept/握手都正常，问题在 hev 侧(可能隧道路由循环/库行为)
    //     连不上(timeout/refused) = appex 自身回环被隧道路由劫持，需修路由
    private func loopbackSelfTest() {
        let port = socks5Port
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { appexLog("self-test socket fail errno=\(errno)"); return }
        defer { close(fd) }
        // fix3cy35b: 不用 select/FD_SET(C 宏在 Swift 导入易编译失败)，改阻塞 connect + SO_SNDTIMEO 超时
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 {
            appexLog("self-test connect OK")
            let g: [UInt8] = [0x05, 0x01, 0x00]
            let w = g.withUnsafeBytes { send(fd, $0.baseAddress, 3, 0) }
            var buf = [UInt8](repeating: 0, count: 2)
            let r = read(fd, &buf, 2)
            appexLog("self-test handshake w=\(w) r=\(r) reply=\(buf.map { String(format:"%02x", $0) }.joined())")
        } else {
            appexLog("self-test connect FAIL errno=\(errno)")
        }
    }

    // MARK: - utun fd 探测（Tun2SocksKit 内部同款，CHev.h 提供 ctl_info/sockaddr_ctl/CTLIOCGINFO）

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

    /// fix3cy36: 返回 en0 的接口 IPv4(非 loopback、非隧道)——hev 连此地址(被 NE exclude)直达本地 Socks5Server
    private static func lanIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let c = cur {
            let family = c.pointee.ifa_addr.pointee.sa_family
            let name = String(cString: c.pointee.ifa_name)
            if (name == "en0" || name == "en1") && family == sa_family_t(AF_INET) {
                var addr = c.pointee.ifa_addr.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(cString: host)
                    // 排除 loopback 和 hev 隧道内部网段
                    if !s.hasPrefix("127.") && !s.hasPrefix("198.18.") && !s.hasPrefix("fc00:") {
                        return s
                    }
                }
            }
            cur = c.pointee.ifa_next
        }
        return nil
    }

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

    private static func makeConfig(socks5Address: String, port: Int, logPath: String) -> String {
        return """
        tunnel:
          mtu: 1500
          ipv4: 198.18.0.1
          ipv6: 'fc00::1'

        socks5:
          address: \(socks5Address)
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
