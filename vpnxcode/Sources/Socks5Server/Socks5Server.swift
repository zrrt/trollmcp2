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
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
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
            guard cfd >= 0 else { continue }
            queue.async { [weak self] in self?.handleConnection(cfd) }
        }
    }

    // MARK: - 连接处理

    private func handleConnection(_ cfd: Int32) {
        defer { close(cfd) }
        // 1) SOCKS5 握手
        guard let (ver, methods) = readGreeting(cfd), ver == 5 else { return }
        _ = methods
        let ok: [UInt8] = [0x05, 0x00]  // 无需认证
        writeBytes(cfd, ok)
        // 2) 请求
        guard let req = readRequest(cfd) else { return }
        switch req.cmd {
        case 0x01: // CONNECT
            guard let upfd = connectTo(host: req.host, port: req.port) else {
                writeReply(cfd, rep: 0x05)  // 连接拒绝
                return
            }
            defer { close(upfd) }
            writeReply(cfd, rep: 0x00)  // 成功
            pumpBidirectional(cfd, upfd, host: req.host, port: req.port)
        case 0x03: // UDP ASSOCIATE
            handleUdpAssociate(cfd, clientAddr: req.client)
        default:
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
            return nil
        }
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

    private func connectTo(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        guard getaddrinfo(host, portStr, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(r) }
        var fd: Int32 = -1
        var cur: UnsafeMutablePointer<addrinfo>? = r
        while let c = cur {
            let f = socket(c.pointee.ai_family, c.pointee.ai_socktype, c.pointee.ai_protocol)
            if f >= 0 {
                if connect(f, c.pointee.ai_addr, c.pointee.ai_addrlen) == 0 {
                    fd = f
                    break
                }
                close(f)
            }
            cur = c.pointee.ai_next
        }
        return fd >= 0 ? fd : nil
    }

    // MARK: - 转发 + 记录

    private func pumpBidirectional(_ cfd: Int32, _ upfd: Int32, host: String, port: UInt16) {
        let logPath = logFile(host: host, port: port)
        let q = DispatchQueue.global(qos: .default)
        let group = DispatchGroup()
        group.enter()
        q.async {
            self.pump(from: cfd, to: upfd, logPath: logPath, dir: "C->S")
            group.leave()
        }
        group.enter()
        q.async {
            self.pump(from: upfd, to: cfd, logPath: logPath, dir: "S->C")
            group.leave()
        }
        group.wait()
    }

    private func pump(from src: Int32, to dst: Int32, logPath: String, dir: String) {
        var buf = [UInt8](repeating: 0, count: 16384)
        while runningFlag {
            let n = read(src, &buf, 16384)
            if n <= 0 { break }
            var off = 0
            while off < Int(n) {
                let w = write(dst, &buf[off], Int(n) - off)
                if w <= 0 { break }
                off += Int(w)
            }
            if off < Int(n) { break }
            logData(logPath, dir: dir, data: Array(buf[0..<Int(n)]))
        }
        // 半关闭，让对端尽快退出
        shutdown(dst, SHUT_WR)
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
        // 回 BND（127.0.0.1:bport）
        var r: [UInt8] = [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, UInt8(bport >> 8), UInt8(bport & 0xff)]
        writeBytes(cfd, r)

        // 转发循环：收客户端 UDP → 解 SOCKS5 UDP 头 → 发真实目标 → 回包封回客户端
        let logPath = logFile(host: "udp", port: 0)
        var buf = [UInt8](repeating: 0, count: 65536)
        var peer = sockaddr_in()
        var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var sessionPeer = peer  // 记录客户端地址
        while runningFlag {
            let n = withUnsafeMutablePointer(to: &peer) { p -> Int in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(ufd, &buf, 65536, 0, $0, &plen)
                }
            }
            if n <= 0 { continue }
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

    private func logData(_ path: String, dir: String, data: [UInt8]) {
        let ts = String(format: "%.3f", Date().timeIntervalSince1970)
        let hex = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
        let text = String(data: Data(data.prefix(512)), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") ?? ""
        var line = "[\(ts)] \(dir) len=\(data.count)\nHEX: \(hex)\nTXT: \(text)\n"
        if let h = fopen(path, "ab") {
            line.withCString { fwrite($0, 1, strlen($0), h) }
            fclose(h)
        }
    }
}
