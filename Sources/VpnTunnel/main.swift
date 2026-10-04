// EXPERIMENT-vpn-min-shell：最小空壳实验
// 不链接 hev/OpenSSL/Socks5Server，仅 NE 最小 startTunnel。
// 目的：一次实验定位"自研 appex 不被 NE 拉起"根因——
//   能连 ⇒ 问题在静态链接内容（hev/OpenSSL Mach-O 属性）
//   不能连 ⇒ 问题在 swift build 产物 / 编译方式本身
// 实验结束即恢复原 hev 引擎（git 历史 /tmp/vpn_main_backup.swift）。
import Foundation
import NetworkExtension

@objc public class TunnelProvider: NEPacketTunnelProvider {

    public override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[VpnTunnel-min] startTunnel begin (MIN SHELL)")
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        settings.ipv6Settings = NEIPv6Settings(addresses: ["fc00::1"], networkPrefixLengths: [NSNumber(value: 64)])
        settings.mtu = 9000
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("[VpnTunnel-min] setTunnelNetworkSettings FAILED: \(error)")
                completionHandler(error)
            } else {
                NSLog("[VpnTunnel-min] setTunnelNetworkSettings OK")
                completionHandler(nil)
            }
        }
    }

    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[VpnTunnel-min] stopTunnel")
        completionHandler()
    }
}
