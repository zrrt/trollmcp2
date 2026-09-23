// VpnManager：MITM 抓包 VPN/代理控制（v3.3.0）
// 两种模式：
//  - VPN 模式：NEVPNManager + VpnTunnel appex（PacketTunnelProvider + NEProxySettings 自动接管流量）
//  - 本地代理模式：主 App 进程跑 MitmProxy，配合用户手动在 WiFi 设置里配 HTTP 代理
// 证书：首次运行 MitmProxy 自动生成根 CA（Workspace/certs/ca.pem），generateMobileConfig 产出描述文件供安装信任。

import Foundation
import NetworkExtension
import Security
import MitmCore
import CMitm

final class VpnManager {
    static let shared = VpnManager()

    private let manager = NEVPNManager.shared()
    private(set) var localProxyRunning = false
    let proxyPort: UInt16 = 18180

    /// VPN 连接状态（未加载配置时可能不准，先 loadPreferences）
    var vpnStatus: NEVPNStatus { manager.connection.status }
    var vpnConfigured: Bool { manager.protocolConfiguration != nil }

    func loadPreferences(completion: @escaping (Bool) -> Void) {
        manager.loadFromPreferences { err in
            completion(err == nil)
        }
    }

    // MARK: - VPN 模式

    func startVpn(completion: @escaping (String?) -> Void) {
        manager.loadFromPreferences { [weak self] err in
            guard let self = self else { return }
            if let e = err {
                completion("load failed: \(e.localizedDescription)")
                return
            }
            let proto = NETunnelProviderProtocol()
            proto.serverAddress = "trollagent-mitm"
            proto.username = "trollagent"
            proto.providerBundleIdentifier = "com.trollagent.app.VpnTunnel"
            proto.disconnectOnSleep = false
            self.manager.protocolConfiguration = proto
            self.manager.isEnabled = true
            self.manager.localizedDescription = "TrollAgent 抓包 VPN"
            self.manager.saveToPreferences { err2 in
                if let e = err2 {
                    completion("save failed: \(e.localizedDescription)")
                    return
                }
                do {
                    try self.manager.connection.startVPNTunnel()
                    completion(nil)
                } catch {
                    completion("start failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopVpn() {
        manager.connection.stopVPNTunnel()
    }

    // MARK: - 本地代理模式

    @discardableResult
    func startLocalProxy() -> Bool {
        guard !localProxyRunning else { return true }
        let ok = MitmProxy.shared.start(port: proxyPort)
        localProxyRunning = ok
        return ok
    }

    func stopLocalProxy() {
        MitmProxy.shared.stop()
        localProxyRunning = false
    }

    // MARK: - 证书

    /// 根 CA 是否已生成
    var caExists: Bool {
        FileManager.default.fileExists(atPath: MitmProxy.shared.certDir + "/ca.pem")
    }

    /// 生成 mobileconfig 描述文件（含根证书 DER）。返回文件路径，失败 nil。
    func generateMobileConfig() -> String? {
        // 确保 CA 存在（没有则先初始化）
        if !caExists {
            let ok = MitmProxy.shared.start(port: proxyPort)
            if !ok { return nil }
            MitmProxy.shared.stop()
        }
        // iOS 只认 DER：优先读 ca.der；老 CA 没有 der 就现场导出
        let derPath = MitmProxy.shared.certDir + "/ca.der"
        if !FileManager.default.fileExists(atPath: derPath) {
            guard mitm_ca_export_der(MitmProxy.shared.certDir) == 0 else { return nil }
        }
        guard let der = try? Data(contentsOf: URL(fileURLWithPath: derPath)) else { return nil }
        let b64 = der.base64EncodedString()

        let certPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.trollagent.app.mitmca",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "TrollAgent MITM CA",
            "PayloadContent": b64,
            "PayloadCertificateFileName": "TrollAgentCA.der"
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.trollagent.app.mitm",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "TrollAgent 抓包证书",
            "PayloadDescription": "安装并信任后，TrollAgent 可解密 HTTPS 明文用于抓包分析",
            "PayloadContent": [certPayload]
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0) else { return nil }
        let path = MitmProxy.shared.certDir + "/TrollAgentCA.mobileconfig"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    /// 抓包记录目录
    var mitmLogDir: String { MitmProxy.shared.logDir }

    /// 根证书目录（含 ca.pem / ca.der / mobileconfig）
    var certDir: String { MitmProxy.shared.certDir }
}
