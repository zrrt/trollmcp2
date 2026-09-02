import Foundation

/// Gateway 客户端：通过 WebSocket 与 Mac/Linux/NAS 上的 Gateway 服务端配对。
/// 真实握手流程：建连 → 发送 hello(携带 token) → 等待服务端 ready/connected/paired 确认 → 置 isConnected。
final class GatewayClient: ObservableObject {
    static let shared = GatewayClient()

    @Published var isConnected = false
    @Published var serverURL: String = ""
    @Published var lastError: String?
    @Published var pairedToken: String?
    @Published var lastEvent: String?

    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let key = "trollmcp2.gateway_url"
    private let tokenKey = "trollmcp2.gateway_token"

    private var handshakeCompletion: ((Bool, String?) -> Void)?
    private var handshakeTimeout: DispatchWorkItem?
    private var handshakeResolved = false

    private let handshakeTimeoutSeconds: Double = 10

    init() {
        serverURL = UserDefaults.standard.string(forKey: key) ?? ""
        pairedToken = UserDefaults.standard.string(forKey: tokenKey)
        // v2.9.10：网络恢复 / 回前台自动重连（解决"切后台再回来连接中断"）
        // 用闭包观察者而非 #selector（GatewayClient 非 NSObject 子类，#selector 不可用）
        NotificationCenter.default.addObserver(
            forName: AppLifecycleMonitor.networkRestored, object: nil, queue: .main
        ) { [weak self] _ in
            self?.autoReconnect()
        }
        NotificationCenter.default.addObserver(
            forName: AppLifecycleMonitor.willEnterForeground, object: nil, queue: .main
        ) { [weak self] _ in
            self?.autoReconnect()
        }
    }

    /// 网络恢复或回前台时：若之前连接过且当前断连，自动重连
    private func autoReconnect() {
        guard !isConnected,
              let url = UserDefaults.standard.string(forKey: key), !url.isEmpty else { return }
        let token = UserDefaults.standard.string(forKey: tokenKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, !self.isConnected else { return }
            self.connect(url: url, token: token)
            AuditLog.shared.log("gateway.auto_reconnect", detail: "网络恢复自动重连: \(url)")
        }
    }

    // MARK: - 连接 + 真实握手

    func connect(url: String, token: String? = nil,
                 completion: ((Bool, String?) -> Void)? = nil) {
        disconnect()
        serverURL = url
        pairedToken = token ?? pairedToken
        UserDefaults.standard.set(url, forKey: key)
        if let t = pairedToken { UserDefaults.standard.set(t, forKey: tokenKey) }

        guard let wsURL = URL(string: url) else {
            lastError = "无效 URL"
            completion?(false, "invalid url")
            return
        }
        var request = URLRequest(url: wsURL)
        if let t = pairedToken, !t.isEmpty {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()

        handshakeResolved = false
        handshakeCompletion = completion

        // 超时保护
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !self.handshakeResolved else { return }
            self.handshakeResolved = true
            self.lastError = "握手超时（\(self.handshakeTimeoutSeconds)s 内未收到服务端确认）"
            self.disconnect()
            self.handshakeCompletion?(false, self.lastError)
            self.handshakeCompletion = nil
        }
        handshakeTimeout = timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + handshakeTimeoutSeconds, execute: timeout)

        // 发送 hello（携带 token 做配对）
        let hello: [String: Any] = [
            "type": "hello",
            "client": "TrollMCP2",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            "token": pairedToken ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: hello),
           let text = String(data: data, encoding: .utf8) {
            send(text)
        }

        receive()
    }

    func disconnect() {
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
    }

    func send(_ text: String) {
        webSocket?.send(.string(text)) { [weak self] error in
            if let error = error { self?.lastError = error.localizedDescription }
        }
    }

    // MARK: - 接收循环

    private func receive() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text = text {
                    self.handleInbound(text)
                }
                self.receive() // 继续监听
            case .failure(let error):
                DispatchQueue.main.async {
                    if !self.handshakeResolved {
                        self.handshakeResolved = true
                        self.lastError = "连接失败: \(error.localizedDescription)"
                        self.isConnected = false
                        self.handshakeCompletion?(false, self.lastError)
                        self.handshakeCompletion = nil
                    } else {
                        self.isConnected = false
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// 解析服务端下行消息；握手阶段等待确认，之后按 channel/node/cron 分类
    private func handleInbound(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AuditLog.shared.log("gateway.rx", detail: text.prefix(200).description)
            return
        }
        let type = (obj["type"] as? String) ?? ""

        if !handshakeResolved {
            let ok = type == "ready" || type == "connected" || type == "paired"
                || type == "ok" || (obj["status"] as? String) == "connected"
                || (obj["connected"] as? Bool) == true
            if ok {
                handshakeResolved = true
                handshakeTimeout?.cancel()
                DispatchQueue.main.async { self.isConnected = true }
                AuditLog.shared.log("gateway.connect", detail: "握手成功: \(serverURL)")
                handshakeCompletion?(true, nil)
                handshakeCompletion = nil
                return
            }
            // 握手阶段收到非确认消息：视为连接失败（缺少握手确认）
            if type == "error" || (obj["status"] as? String) == "error" {
                handshakeResolved = true
                handshakeTimeout?.cancel()
                let err = (obj["message"] as? String) ?? "握手被拒绝"
                DispatchQueue.main.async { self.lastError = err }
                disconnect()
                handshakeCompletion?(false, err)
                handshakeCompletion = nil
                return
            }
            // 其它消息：继续等待确认（保持连接）
            return
        }

        // 已连接：分类记录事件
        DispatchQueue.main.async { self.lastEvent = text.prefix(200).description }
        switch type {
        case "channel":
            AuditLog.shared.log("gateway.channel", detail: "\(obj["channel"] as? String ?? "")")
        case "node_result", "node_invoke_result":
            AuditLog.shared.log("gateway.node", detail: "\(obj["node"] as? String ?? "")")
        case "cron", "cron_event":
            AuditLog.shared.log("gateway.cron", detail: "\(obj["name"] as? String ?? "")")
        default:
            AuditLog.shared.log("gateway.rx", detail: text.prefix(200).description)
        }
    }
}
