// Socks5Server：内置 SOCKS5 代理服务器（appex 内跑，hev-socks5-tunnel 的出口）
// 链路：全接管 VPN 隧道 → hev(lwip 栈，终止 TCP/UDP) → 本机 SOCKS5(127.0.0.1:19080)
//      → Socks5Server 出真实网络 + 记录 → 响应回 hev → writePackets 写回隧道 = 不断网。
// 第一版：纯转发 + hexlog 记录原始字节流（保证不断网优先；MITM 解密后续版本在 CONNECT 上叠加）。
// 协议：SOCKS5（RFC 1928）——握手(VER/NMETHODS/METHODS→0x05,0x00) → 请求(CMD/ATYP/ADDR/PORT)
//     CONNECT(0x01) 双向字节流；UDP ASSOCIATE(0x03) 数据报 [RSV2|FRAG|ATYP|ADDR|PORT|DATA]。
import Foundation
import Darwin

public final class Socks5Server {
    public static let shared = Socks5Server()

    private var listenFD: Int32 = -1
    private var runningFlag = false
    private let queue = DispatchQueue(label: "socks5.proxy", qos: .default, attributes: .concurrent)
    public private(set) var port: UInt16 = 19080
    public let logDir: String
    // fix3cy31: C->S 与 S->C 两个线程共享同一 FILE* 句柄写日志，用互斥锁串行化，避免并发 fwrite 损坏/崩溃
    private var logLock = pthread_mutex_t()

    // fix3cy32: Socks5Server 诊断日志（写 AppGroup，主 App 与 appex 都能读），定位"accept/握手/connectTo/pump"卡点。
    //   现象：hev 反复连 127.0.0.1:19080 但抓包目录空 → 转发未打通，需看每步走到哪。
    // fix3cy37: 高频并发下 fopen("a") 竞态丢日志(accept 洪流时 handleConnection 日志大量丢失)→ 改串行队列写，保证诊断可靠。
    private let logQ = DispatchQueue(label: "socks5.log", qos: .utility)
    private func s5log(_ msg: String) {
        logQ.sync {
            let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ai.iosxcode")
            guard let base = g?.path else { return }
            let p = base + "/socks5_debug.log"
            try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            if let h = fopen(p, "a") {
                let line = "[\(Int(Date().timeIntervalSince1970))] \(msg)\n"
                line.withCString { fwrite($0, 1, strlen($0), h) }
                fclose(h)
            }
        }
    }

    // Step B: appex 无 no-sandbox，日志写不进主 App 容器(/var/mobile/Documents/Workspace)。
    //   改写入 AppGroup 共享容器 (group.com.ai.iosxcode)——主 App 与 appex 都能读。
    public init(workspace: String? = nil) {
        if let ws = workspace {
            logDir = ws + "/network_capture/socks5"
        } else if let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ai.iosxcode") {
            logDir = g.path + "/network_capture/socks5"
        } else {
            logDir = "/var/mobile/Documents/Workspace/network_capture/socks5"
        }
        pthread_mutex_init(&logLock, nil)
    }

    public var isRunning: Bool { runningFlag }

    public func start(port: UInt16 = 19080) -> Bool {
        guard !runningFlag else { return true }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY  // fix3cy36: 监听 0.0.0.0——hev 走 LAN IP(被 NE exclude)直达；127.0.0.1 会被隧道劫持
        let bindOK = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else { close(fd); return false }
        guard listen(fd, 64) == 0 else { close(fd); return false }
        listenFD = fd
        self.port = port
        runningFlag = true
        queue.async { [weak self] in self?.acceptLoop() }
        return true
    }

    public func stop() {
        runningFlag = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop() {
        while runningFlag {
            var client = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &client) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            if cfd < 0 {
                s5log("accept FAILED errno=\(errno)")
                continue
            }
            s5log("accept fd=\(cfd)")
            queue.async { [weak self] in self?.handleConnection(cfd) }
        }
    }

    // MARK: - 连接处理

    private func handleConnection(_ cfd: Int32) {
        defer { close(cfd) }
        s5log("handleConnection fd=\(cfd)")
        // 1) SOCKS5 握手
        guard let (ver, methods) = readGreeting(cfd) else { s5log("GREETING FAIL fd=\(cfd)"); return }
        s5log("greeting ok ver=\(ver) methods=\(methods)")
        _ = methods
        let ok: [UInt8] = [0x05, 0x00]  // 无需认证
        writeBytes(cfd, ok)
        // 2) 请求
        guard let req = readRequest(cfd) else { s5log("REQUEST FAIL fd=\(cfd)"); return }
        s5log("request cmd=\(req.cmd) host=\(req.host):\(req.port)")
        switch req.cmd {
        case 0x01: // CONNECT
            guard let upfd = connectTo(host: req.host, port: req.port) else {
                s5log("connectTo FAIL \(req.host):\(req.port)")
                writeReply(cfd, rep: 0x05)  // 连接拒绝
                return
            }
            s5log("connectTo OK \(req.host):\(req.port) upfd=\(upfd)")
            defer { close(upfd) }
            writeReply(cfd, rep: 0x00)  // 成功
            pumpBidirectional(cfd, upfd, host: req.host, port: req.port)
            s5log("pump done \(req.host):\(req.port)")
        case 0x03: // UDP ASSOCIATE
            handleUdpAssociate(cfd, clientAddr: req.client)
        default:
            s5log("unsupported cmd=\(req.cmd)")
            writeReply(cfd, rep: 0x07)  // 不支持的 CMD
        }
    }

    // MARK: - SOCKS5 解析

    private func readGreeting(_ fd: Int32) -> (ver: UInt8, methods: [UInt8])? {
        var buf = [UInt8](repeating: 0, count: 2)
        guard readExact(fd, &buf, 2) else { return nil }
        let ver = buf[0]
        let n = Int(buf[1])
        guard n > 0, n <= 255 else { return nil }
        var methods = [UInt8](repeating: 0, count: n)
        guard readExact(fd, &methods, n) else { return nil }
        return (ver, methods)
    }

    private struct SocksRequest {
        let cmd: UInt8
        let host: String
        let port: UInt16
        let client: sockaddr_in
    }

    private func readRequest(_ fd: Int32) -> SocksRequest? {
        var hdr = [UInt8](repeating: 0, count: 4)
        guard readExact(fd, &hdr, 4) else { return nil }
        s5log("req hdr=\(hdr.map { String(format: "%02x", $0) }.joined())")  // fix3cy37: 原始 CONNECT 字节，看 hev 到底发什么
        guard hdr[0] == 5, hdr[2] == 0 else { return nil }
        let cmd = hdr[1]
        let atyp = hdr[3]
        var host = ""
        switch atyp {
        case 1: // IPv4
            var ip = [UInt8](repeating: 0, count: 4)
            guard readExact(fd, &ip, 4) else { return nil }
            host = "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
        case 3: // domain
            var lenB = [UInt8](repeating: 0, count: 1)
            guard readExact(fd, &lenB, 1) else { return nil }
            let len = Int(lenB[0])
            guard len > 0 else { return nil }
            var name = [UInt8](repeating: 0, count: len)
            guard readExact(fd, &name, len) else { return nil }
            host = String(bytes: name, encoding: .utf8) ?? ""
        case 4: // IPv6
            var ip = [UInt8](repeating: 0, count: 16)
            guard readExact(fd, &ip, 16) else { return nil }
            host = ip.map { String(format: "%02x", $0) }.joined(separator: ":")
        default:
            s5log("req atyp=\(atyp) UNSUPPORTED")
            return nil
        }
        s5log("req cmd=\(cmd) atyp=\(atyp) host='\(host)' hlen=\(host.utf8.count)")
        var portB = [UInt8](repeating: 0, count: 2)
        guard readExact(fd, &portB, 2) else { return nil }
        let port = UInt16(portB[0]) << 8 | UInt16(portB[1])

        // 客户端来源（UDP ASSOCIATE 回包用）
        var client = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &client) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len)
            }
        }
        return SocksRequest(cmd: cmd, host: host, port: port, client: client)
    }

    /// 回 SOCKS5 响应：VER=5 REP RSV ATYP BND.ADDR BND.PORT（BND=127.0.0.1:0）
    private func writeReply(_ fd: Int32, rep: UInt8) {
        var r: [UInt8] = [0x05, rep, 0x00, 0x01, 127, 0, 0, 1, 0, 0]
        writeBytes(fd, r)
    }

    private func readExact(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let r = read(fd, &buf[off], n - off)
            if r <= 0 { return false }
            off += Int(r)
        }
        return true
    }

    private func writeBytes(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { ptr in
            var off = 0
            let len = bytes.count
            while off < len {
                let w = write(fd, ptr.baseAddress! + off, len - off)
                if w <= 0 { break }
                off += Int(w)
            }
        }
    }

    // MARK: - 出网连接（复用与 MitmProxy 相同的 getaddrinfo 逻辑）
    // fix3cy38: 出网 socket 绑定 en0 LAN IP（源/回包都走 NE excludedRoutes，绕开隧道，否则 download=0）

    private func connectTo(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        guard getaddrinfo(host, portStr, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(r) }
        let lanIP = getLanIPv4()
        var fd: Int32 = -1
        var cur: UnsafeMutablePointer<addrinfo>? = r
        while let c = cur {
            let f = socket(c.pointee.ai_family, c.pointee.ai_socktype, c.pointee.ai_protocol)
            if f >= 0 {
                if let ip = lanIP, c.pointee.ai_family == AF_INET {
                    bindToLan(f, ip)
                }
                if connectWithTimeout(f, c.pointee.ai_addr, c.pointee.ai_addrlen, timeout: 8) == 0 {
                    fd = f
                    var local = sockaddr_in(); var llen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    getsockname(f, withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &llen)
                    var srcIP = [CChar](repeating: 0, count: 64)
                    inet_ntop(AF_INET, &local.sin_addr, &srcIP, 64)
                    s5log("connectTo OK src=\(String(cString: srcIP)) -> \(host):\(port)")
                    break
                }
                close(f)
            }
            cur = c.pointee.ai_next
        }
        return fd >= 0 ? fd : nil
    }

    private func bindToLan(_ fd: Int32, _ ip: String) {
        var sa = sockaddr_in()
        sa.sin_family = AF_INET
        sa.sin_port = 0
        if inet_pton(AF_INET, ip, &sa.sin_addr) == 1 {
            withUnsafePointer(to: &sa) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func connectWithTimeout(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t, timeout: Int) -> Int32 {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = Darwin.connect(fd, addr, len)
        if r == 0 { return 0 }
        if errno != EINPROGRESS { return -1 }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, Int32(timeout * 1000))
        if pr <= 0 { return -1 }
        var soerr: Int32 = 0
        var len2 = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len2)
        return soerr == 0 ? 0 : -1
    }

    private func getLanIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            let family = ifa.pointee.ifa_addr.pointee.sa_family
            if family == AF_INET {
                let name = String(cString: ifa.pointee.ifa_name)
                if name != "lo0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ifa.pointee.ifa_addr, socklen_t(ifa.pointee.ifa_addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.hasPrefix("198.18.") && !ip.hasPrefix("fc00:") && ip != "127.0.0.1" {
                            return ip
                        }
                    }
                }
            }
            ptr = ifa.pointee.ifa_next
        }
        return nil
    }

    // MARK: - 转发 + 记录

    private func pumpBidirectional(_ cfd: Int32, _ upfd: Int32, host: String, port: UInt16) {
        // fix3cy33: 去掉逐块 hexlog（52MB 存储元凶），改会话结束时写一行 SQLite。
        //   中继热路径只做 read→write，字节数累加，结束后 CaptureDB.logSession 一次落库。
        let start = Int64(Date().timeIntervalSince1970 * 1000)
        let q = DispatchQueue.global(qos: .default)
        let group = DispatchGroup()
        var upTotal: Int64 = 0
        var downTotal: Int64 = 0
        group.enter()
        q.async {
            upTotal = self.pump(from: cfd, to: upfd, dir: "C->S")
            group.leave()
        }
        group.enter()
        q.async {
            downTotal = self.pump(from: upfd, to: cfd, dir: "S->C")
            group.leave()
        }
        group.wait()
        let end = Int64(Date().timeIntervalSince1970 * 1000)
        s5log("session \(host):\(port) up=\(upTotal) down=\(downTotal)")
        CaptureDB.shared.logSession(proto: "tcp", host: host, port: port,
                                    up: upTotal, down: downTotal, start: start, end: end)
    }

    private func pump(from src: Int32, to dst: Int32, dir: String) -> Int64 {
        var buf = [UInt8](repeating: 0, count: 16384)
        var total: Int64 = 0
        while runningFlag {
            let n = read(src, &buf, 16384)
            if n <= 0 { break }
            total += Int64(n)
            var off = 0
            while off < Int(n) {
                let w = write(dst, &buf[off], Int(n) - off)
                if w <= 0 { break }
                off += Int(w)
            }
            if off < Int(n) { break }
        }
        // 半关闭，让对端尽快退出
        shutdown(dst, SHUT_WR)
        return total
    }

    private func handleUdpAssociate(_ cfd: Int32, clientAddr: sockaddr_in) {
        // 绑本地 UDP socket
        let ufd = socket(AF_INET, SOCK_DGRAM, 0)
        guard ufd >= 0 else { return }
        defer { close(ufd) }
        var opt: Int32 = 1
        setsockopt(ufd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // 系统分配
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(ufd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else { return }
        // 取实际绑定的端口
        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(ufd, $0, &blen)
            }
        }
        let bport = UInt16(bound.sin_port.bigEndian)
        s5log("UDP ASSOCIATE bound 127.0.0.1:\(bport) fd=\(cfd)")
        // 回 BND（127.0.0.1:bport）
        var r: [UInt8] = [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, UInt8(bport >> 8), UInt8(bport & 0xff)]
        writeBytes(cfd, r)

        // 转发循环：收客户端 UDP → 解 SOCKS5 UDP 头 → 发真实目标 → 回包封回客户端
        let logPath = logFile(host: "udp", port: 0)
        var buf = [UInt8](repeating: 0, count: 65536)
        var peer = sockaddr_in()
        var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var sessionPeer = peer  // 记录客户端地址
        var dgramCount = 0
        while runningFlag {
            let n = withUnsafeMutablePointer(to: &peer) { p -> Int in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(ufd, &buf, 65536, 0, $0, &plen)
                }
            }
            if n <= 0 { continue }
            dgramCount += 1
            s5log("udp dgram #\(dgramCount) n=\(n)")
            let data = Array(buf[0..<Int(n)])
            guard data.count >= 4, data[0] == 0, data[1] == 0, data[2] == 0 else { continue }
            let atyp = data[3]
            var idx = 4
            var dstHost = ""
            switch atyp {
            case 1:
                guard data.count >= idx + 4 else { continue }
                dstHost = "\(data[idx]).\(data[idx+1]).\(data[idx+2]).\(data[idx+3])"
                idx += 4
            case 3:
                let l = Int(data[idx]); idx += 1
                guard data.count >= idx + l else { continue }
                dstHost = String(bytes: data[idx..<(idx+l)], encoding: .utf8) ?? ""
                idx += l
            case 4:
                guard data.count >= idx + 16 else { continue }
                dstHost = data[idx..<(idx+16)].map { String(format: "%02x", $0) }.joined(separator: ":")
                idx += 16
            default:
                continue
            }
            guard data.count >= idx + 2 else { continue }
            let dport = UInt16(data[idx]) << 8 | UInt16(data[idx+1])
            idx += 2
            let payload = Array(data[idx...])
            sessionPeer = peer
            logData(logPath, dir: "C->U", data: [UInt8]("\(dstHost):\(dport) ".utf8) + payload)

            // 发真实目标
            sendUdp(ufd, host: dstHost, port: dport, payload: payload)
        }
        _ = sessionPeer
    }

    private func sendUdp(_ ufd: Int32, host: String, port: UInt16, payload: [UInt8]) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let r = res else { return }
        defer { freeaddrinfo(r) }
        payload.withUnsafeBytes { p in
            sendto(ufd, p.baseAddress, payload.count, 0, r.pointee.ai_addr, r.pointee.ai_addrlen)
        }
    }

    // MARK: - 记录（hexlog）

    private func logFile(host: String, port: UInt16) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let safe = host.replacingOccurrences(of: ":", with: "_")
        return logDir + "/" + df.string(from: Date()) + "_" + safe + "_" + String(port) + ".log"
    }

    private func logData(_ h: UnsafeMutablePointer<FILE>?, dir: String, data: [UInt8]) {
        guard let h = h else { return }
        let ts = String(format: "%.3f", Date().timeIntervalSince1970)
        let hex = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
        let text = String(data: Data(data.prefix(512)), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") ?? ""
        let line = "[\(ts)] \(dir) len=\(data.count)\nHEX: \(hex)\nTXT: \(text)\n"
        pthread_mutex_lock(&logLock)
        line.withCString { fwrite($0, 1, strlen($0), h) }
        pthread_mutex_unlock(&logLock)
    }

    // UDP 路径沿用（数据报较小，逐包打开可接受）
    private func logData(_ path: String, dir: String, data: [UInt8]) {
        if let h = fopen(path, "ab") {
            logData(h, dir: dir, data: data)
            fclose(h)
        }
    }
}
