// LocalHttpServer：极简本地 HTTP 服务（v3.3.1）
// 用途：把 mobileconfig 描述文件用 Safari 打开下载 —— 触发系统标准
// "此网站正尝试下载一个配置描述文件" 确认框（Shadowrocket/QuanX 同款流程），
// 解决无沙箱侧载环境下「文件 App 打开描述文件不弹安装」的问题。
// 仅监听 127.0.0.1，只允许 .mobileconfig 文件，不对外网开放。

import Foundation

final class LocalHttpServer {
    static let shared = LocalHttpServer()

    private var listenFD: Int32 = -1
    private var rootDir = ""
    private let port: UInt16 = 18080
    private let queue = DispatchQueue(label: "local.http.accept", qos: .userInitiated)

    var serverURL: String { "http://127.0.0.1:\(port)" }

    @discardableResult
    func start(rootDir: String) -> Bool {
        if listenFD >= 0 { return true }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound else { close(fd); return false }
        guard listen(fd, 8) == 0 else { close(fd); return false }
        listenFD = fd
        self.rootDir = rootDir
        queue.async { [weak self] in self?.acceptLoop() }
        return true
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var client = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &client) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            guard cfd >= 0 else { continue }
            DispatchQueue.global().async { [weak self] in self?.handle(cfd) }
        }
    }

    private func handle(_ cfd: Int32) {
        defer { close(cfd) }
        var buf = [UInt8](repeating: 0, count: 16384)
        let n = read(cfd, &buf, buf.count)
        guard n > 0 else { return }
        let raw = String(decoding: buf[0..<n], as: UTF8.self)
        let firstLine = raw.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        var path = String(parts[1])
        if let qi = path.firstIndex(of: "?") { path = String(path[..<qi]) }
        // 防目录穿越：只允许文件名（/name.mobileconfig）
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".mobileconfig") else {
            writeAll(cfd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let fileURL = URL(fileURLWithPath: rootDir).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: fileURL) else {
            writeAll(cfd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-apple-aspen-config\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        writeAll(cfd, head)
        data.withUnsafeBytes { p in
            guard let base = p.baseAddress else { return }
            _ = write(cfd, base, data.count)
        }
    }

    private func writeAll(_ fd: Int32, _ s: String) {
        let d = Data(s.utf8)
        d.withUnsafeBytes { p in
            guard let base = p.baseAddress else { return }
            _ = write(fd, base, d.count)
        }
    }
}
