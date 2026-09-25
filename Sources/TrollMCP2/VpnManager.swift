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

    // v3.5.2：packet-tunnel 网络扩展必须用 NETunnelProviderManager。
    // 之前用 NEVPNManager.shared()（IPSec/IKEv2 旧版 VPN 管理器）挂 NETunnelProviderProtocol，
    // 系统不会在"设置→VPN"注册、startVPNTunnel 也不生效——表现为"VPN 不显示、打不开"。
    private var manager = NETunnelProviderManager()
    private(set) var localProxyRunning = false
    let proxyPort: UInt16 = 18180

    /// VPN 连接状态（未加载配置时可能不准，先 loadPreferences）
    var vpnStatus: NEVPNStatus { manager.connection.status }
    var vpnConfigured: Bool { manager.protocolConfiguration != nil }

    /// v3.3.2：开关状态 = VPN 已连接/连接中 或 本地代理运行中
    var vpnActive: Bool {
        let s = manager.connection.status
        return s == .connected || s == .connecting || localProxyRunning
    }

    /// v3.3.2：一键开/关（AI 的 vpn.capture start/stop 走同一底层；开关失败回调 err）
    func toggleVpn(completion: @escaping (String?) -> Void = { _ in }) {
        if vpnActive {
            stopVpn()
            stopLocalProxy()
            completion(nil)
        } else {
            startVpn(completion: completion)
        }
    }

    func loadPreferences(completion: @escaping (Bool) -> Void) {
        manager.loadFromPreferences { err in
            completion(err == nil)
        }
    }

    // MARK: - VPN 模式

    func startVpn(completion: @escaping (String?) -> Void) {
        // v3.5.16f：对齐 Apple 可运行案例(100518/104280/661560)的启动流程——
        // ① 用 loadAllFromPreferences 拿系统"注册过"的 manager(而非新建 NETunnelProviderManager())；
        // ② saveToPreferences 之后必须再 loadFromPreferences 一次，把 manager 绑定到系统刚保存的
        //    配置，再 startVPNTunnel。此前"新建 manager + save 后直接 start"导致系统按 providerBundleIdentifier
        //    建不出扩展("Failed to create an NSExtension with type …: (null)")→ NEVPNErrorConfigurationInvalid(1)。
        startVpnViaRegisteredManager(retryLeft: 1, completion: completion)
    }

    /// 通过 loadAllFromPreferences 拿系统注册的 manager（找不到则新建），按需清失效配置后保存并启动。
    private func startVpnViaRegisteredManager(retryLeft: Int, completion: @escaping (String?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            // 优先复用系统已注册的"TrollAgent 抓包 VPN"配置；没有则新建。
            self.manager = managers?.first(where: { $0.localizedDescription == "TrollAgent 抓包 VPN" })
                              ?? NETunnelProviderManager()
            self.manager.loadFromPreferences { [weak self] _ in
                guard let self = self else { return }
                // 残留的是失效配置(非 packet-tunnel 协议)才清；正常直接保存。
                let isStale = (self.manager.protocolConfiguration != nil)
                             && !(self.manager.protocolConfiguration is NETunnelProviderProtocol)
                if isStale {
                    self.manager.removeFromPreferences { [weak self] _ in
                        self?.saveAndStart(retryLeft: retryLeft, completion: completion)
                    }
                } else {
                    self.saveAndStart(retryLeft: retryLeft, completion: completion)
                }
            }
        }
    }

    /// 组装全新 NETunnelProviderProtocol 配置 → save → 重新 load → startVPNTunnel；失败可重试一次。
    private func saveAndStart(retryLeft: Int, completion: @escaping (String?) -> Void) {
        let proto = NETunnelProviderProtocol()
        // v3.3.3：serverAddress 必须是合法地址（此前 "trollagent-mitm" 被系统判为 invalid protocol）
        proto.serverAddress = "127.0.0.1"
        proto.providerBundleIdentifier = "com.trollagent.app.VpnTunnel"
        proto.disconnectOnSleep = false
        self.manager.protocolConfiguration = proto
        self.manager.isEnabled = true
        self.manager.localizedDescription = "TrollAgent 抓包 VPN"
        self.manager.saveToPreferences { [weak self] err2 in
            guard let self = self else { return }
            if let e = err2 {
                completion("save failed: \(e.localizedDescription)")
                return
            }
            // 关键：save 后重新 loadFromPreferences，使 manager.connection 绑定到系统刚保存的配置，再启动。
            self.manager.loadFromPreferences { [weak self] _ in
                guard let self = self else { return }
                do {
                    try self.manager.connection.startVPNTunnel()
                    completion(nil)
                } catch {
                    let ne = error as? NEVPNError
                    let code = ne.map { " NEVPNErrorCode=\($0.code.rawValue)" } ?? ""
                    if retryLeft > 0 {
                        // 重试：清掉配置，再走一遍"注册 manager"流程
                        self.manager.removeFromPreferences { [weak self] _ in
                            self?.startVpnViaRegisteredManager(retryLeft: 0, completion: completion)
                        }
                        return
                    }
                    completion("start failed: \(error.localizedDescription)\(code)")
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

        // ⚠️ PayloadContent 必须是 <data>（DER 二进制）类型，iOS 才认：
        // 传 base64 字符串会输出 <string> 导致安装时报 "字段 PayloadContent 无效"。
        let certPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.trollagent.app.mitmca",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "TrollAgent MITM CA",
            "PayloadContent": der,
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
