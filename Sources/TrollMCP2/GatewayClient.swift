import Foundation

/// Gateway 客户端：通过 WebSocket 与 Mac/Linux/NAS 上的 Gateway 服务端配对
final class GatewayClient: ObservableObject {
    static let shared = GatewayClient()

    @Published var isConnected = false
    @Published var serverURL: String = ""
    @Published var lastError: String?
    @Published var pairedToken: String?

    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let key = "trollmcp2.gateway_url"

    init() {
        serverURL = UserDefaults.standard.string(forKey: key) ?? ""
    }

    func connect(url: String) {
        disconnect()
        serverURL = url
        UserDefaults.standard.set(url, forKey: key)

        guard let wsURL = URL(string: url) else {
            lastError = "无效 URL"
            return
        }
        var request = URLRequest(url: wsURL)
        if let token = pairedToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()
        isConnected = true
        receive()
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
    }

    func send(_ text: String) {
        webSocket?.send(.string(text)) { _ in }
    }

    private func receive() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    // 处理 Gateway 下行消息（JSON-RPC）
                    AuditLog.shared.log("gateway.rx", detail: text.prefix(200).description)
                case .data(let data):
                    AuditLog.shared.log("gateway.rx", detail: "\(data.count) bytes")
                @unknown default:
                    break
                }
                self.receive()  // 继续监听
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
}
