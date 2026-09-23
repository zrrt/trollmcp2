// MitmCore：MITM 抓包代理内核（纯 Swift + CMitm C 桥接）
// 被主 App（本地代理模式）与 VpnTunnel appex（VPN 模式）共用。
// 监听 127.0.0.1:<port>，处理 HTTP CONNECT：下游 TLS(伪造证书) ↔ 上游 TLS(真实服务器)，
// 明文双向记录到 Workspace/network_capture/mitm/。

import Foundation
import CMitm
import Darwin

public final class MitmProxy {
    public static let shared = MitmProxy()

    private var listenFD: Int32 = -1
    private var runningFlag = false
    private let queue = DispatchQueue(label: "mitm.proxy", qos: .default)

    public private(set) var port: UInt16 = 18180
    public let certDir: String
    public let logDir: String

    public init(workspace: String = "/var/mobile/Documents/Workspace") {
        certDir = workspace + "/certs"
        logDir = workspace + "/network_capture/mitm"
    }

    public var isRunning: Bool { runningFlag }

    /// 启动代理。首次自动生成根 CA（certs/ca.pem + ca_key.pem）。返回是否成功。
    public func start(port: UInt16 = 18180) -> Bool {
        guard !runningFlag else { return true }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: certDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        guard mitm_ca_init(certDir) == 0 else { return false }

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
        guard let head = readHttpHead(cfd) else { return }
        guard let (host, port) = parseConnect(head) else {
            writeAll(cfd, "HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        }
        guard let upfd = connectTo(host: host, port: port) else { return }
        defer { close(upfd) }

        var cder: UnsafeMutablePointer<UInt8>?
        var clen: Int = 0
        var kder: UnsafeMutablePointer<UInt8>?
        var klen: Int = 0
        guard mitm_sign_host(host, &cder, &clen, &kder, &klen) == 0, cder != nil, kder != nil else { return }
        defer {
            if let c = cder { mitm_free(c) }
            if let k = kder { mitm_free(k) }
        }

        guard let upTls = mitm_tls_connect(upfd, host) else { return }
        defer { mitm_close(upTls) }

        writeAll(cfd, "HTTP/1.1 200 Connection Established\r\n\r\n")

        guard let downTls = mitm_tls_accept(cfd, cder, clen, kder, klen) else { return }
        defer { mitm_close(downTls) }

        let logPath = logFile(host: host)
        let q = DispatchQueue.global(qos: .default)
        // 双向转发。任一方 EOF 后，尽力让另一方感知关闭：EOF 方对另一端做 shutdown 写
        let group = DispatchGroup()
        group.enter()
        q.async {
            self.pump(from: downTls, to: upTls, logPath: logPath, dir: "C->S")
            group.leave()
        }
        group.enter()
        q.async {
            self.pump(from: upTls, to: downTls, logPath: logPath, dir: "S->C")
            group.leave()
        }
        group.wait()
    }

    private func pump(from src: OpaquePointer, to dst: OpaquePointer, logPath: String, dir: String) {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 16384)
        defer { buf.deallocate() }
        while runningFlag {
            let n = mitm_read(src, buf, 16384)
            if n <= 0 { break }
            let w = mitm_write(dst, buf, n)
            if w <= 0 { break }
            logData(logPath, dir: dir, buf: buf, len: n)
        }
        // 通知对端连接已结束（半关闭写端），让另一方向尽快退出
        mitm_shutdown(dst)
    }

    // MARK: - 记录

    private func logFile(host: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let safe = host.replacingOccurrences(of: ":", with: "_")
        return logDir + "/" + df.string(from: Date()) + "_" + safe + ".txt"
    }

    private func logData(_ path: String, dir: String, buf: UnsafeMutablePointer<CChar>, len: Int32) {
        let d = Data(bytes: buf, count: Int(len))
        let ts = String(format: "%.3f", Date().timeIntervalSince1970)
        var line = "[\(ts)] \(dir) len=\(d.count)\n"
        let hex = d.prefix(128).map { String(format: "%02x", $0) }.joined(separator: " ")
        line += "HEX: \(hex)\n"
        let text = String(data: d.prefix(512), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") ?? ""
        line += "TXT: \(text)\n"
        if let h = fopen(path, "ab") {
            line.withCString { fwrite($0, 1, strlen($0), h) }
            fclose(h)
        }
    }

    // MARK: - 底层 IO

    private func readHttpHead(_ fd: Int32) -> String? {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
        defer { buf.deallocate() }
        var data = Data()
        while data.count < 8192 {
            let n = read(fd, buf, 8192)
            if n <= 0 { return nil }
            data.append(buf, count: n)
            if let s = String(data: data, encoding: .ascii), s.contains("\r\n\r\n") {
                return s
            }
        }
        return nil
    }

    private func parseConnect(_ head: String) -> (host: String, port: UInt16)? {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else { return nil }
        let target = parts[1]
        let hp = target.split(separator: ":")
        guard hp.count >= 2, let port = UInt16(hp[hp.count - 1]) else { return nil }
        let host = hp[0..<(hp.count - 1)].joined(separator: ":")
        return (String(host), port)
    }

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

    private func writeAll(_ fd: Int32, _ s: String) {
        s.withCString { ptr in
            var off = 0
            let len = strlen(ptr)
            while off < len {
                let w = write(fd, ptr + off, len - off)
                if w <= 0 { break }
                off += w
            }
        }
    }
}
