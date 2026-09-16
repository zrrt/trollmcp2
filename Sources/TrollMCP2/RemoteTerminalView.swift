import SwiftUI

/// v2.9.181：远程终端配置页
/// TrollAgent 自身开公网 HTTP API（监听 0.0.0.0:8790），
/// N1 公网端口转发到手机局域网 IP 后，云端 AI 可直接读取/调用/审计。
struct RemoteTerminalView: View {
    @State private var token: String = RemoteTerminalServer.shared.token
    @State private var portText: String = "\(RemoteTerminalServer.shared.port)"
    @State private var allowDangerous = RemoteTerminalServer.shared.allowDangerous
    @State private var running = RemoteTerminalServer.shared.isRunning
    @State private var toast: String?
    @State private var lanIP = Self.localIPAddress()

    var body: some View {
        Form {
            Section(header: Text("服务"), footer: Text(running ? "服务运行中：0.0.0.0:\(portText)。请保持 App 在前台或开启后台常驻，否则被杀后服务不可达。" : "启动后监听 0.0.0.0:\(portText)，局域网与公网（经 N1 转发）均可访问。")) {
                Toggle("远程终端服务", isOn: $running)
                    .onChange(of: running) { on in
                        if on {
                            RemoteTerminalServer.shared.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                            RemoteTerminalServer.shared.port = Int(portText) ?? 8790
                            RemoteTerminalServer.shared.allowDangerous = allowDangerous
                            let ok = RemoteTerminalServer.shared.start()
                            toast = ok ? "已启动 :\(RemoteTerminalServer.shared.port)" : "启动失败（端口占用？）"
                        } else {
                            RemoteTerminalServer.shared.stop()
                            toast = "已停止"
                        }
                    }
                TextField("访问令牌（token，必填）", text: $token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("端口（默认 8790）", text: $portText)
                    .keyboardType(.numberPad)
            }

            Section(header: Text("本机地址")) {
                HStack {
                    Text("局域网 IP")
                    Spacer()
                    Text(lanIP.isEmpty ? "获取失败" : lanIP)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("服务地址")
                    Spacer()
                    Text("http://\(lanIP):\(portText)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button("复制局域网地址") {
                    UIPasteboard.general.string = "http://\(lanIP):\(portText)"
                    toast = "已复制"
                }
            }

            Section(header: Text("N1 公网映射"), footer: Text("1. 子域名 A 记录指向 N1 公网 IPv4；2. N1/路由器把公网端口 TCP 转发到手机局域网 IP:\(portText)；3. 云端访问 http://你的域名:公网端口，带 Authorization: Bearer <token>。")) {
                Label("N1 只做端口转发，无需装任何服务", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("危险工具授权"), footer: Text("默认只允许只读诊断工具（状态/文件浏览/日志/审计/注入状态查询）。开启后允许注入、删除、写入、启动 App、抓包等危险工具被远程调用——仅在你完全信任的私网映射下开启。")) {
                Toggle("允许远程执行危险工具", isOn: $allowDangerous)
                    .tint(.red)
                    .onChange(of: allowDangerous) { v in
                        RemoteTerminalServer.shared.allowDangerous = v
                    }
            }

            if let toast {
                Section { Text(toast).font(.caption).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("远程终端")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // 保存
            RemoteTerminalServer.shared.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            RemoteTerminalServer.shared.port = Int(portText) ?? 8790
            RemoteTerminalServer.shared.allowDangerous = allowDangerous
        }
    }

    static func localIPAddress() -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "" }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 { continue }
            if addr.sa_family != UInt8(AF_INET) { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
        return address ?? ""
    }
}
