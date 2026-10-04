// VpnTunnel Provider（Xcode app-extension 形态，P1 Step A）
// Step A：最小 TunnelProvider —— 只写日志，验证 NE 是否真正拉起 Xcode 形态的 appex。
//   NE 拉起链路：nesessionmanager→neagent(PlugInKit)→pkd→RunningBoard→launchd
//   posix_spawn→dyld→_NSExtensionMain（Xcode -e 布线，本文件无 main）→PKService
//   runloop→NSExtensionPrincipalClass 实例化→startTunnel。
// 若本版能连上/有日志 → NE 拉起 OK，Step B 再集成 hev 转发内核（CHev+libhev+MitmCore）。
// 若仍无日志 → 问题在更底层（Mach-O/签名信任层），走调研报告 P0 诊断序列。
import Foundation
import NetworkExtension

func appexLog(_ msg: String) {
    let path = "/var/mobile/Documents/Workspace/logs/appex.log"
    let ts = String(Int(Date().timeIntervalSince1970))
    let line = "[\(ts)] \(msg)\n"
    if let h = fopen(path, "a") {
        fputs(line, h)
        fclose(h)
    }
}

@objc public class TunnelProvider: NEPacketTunnelProvider {

    public override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        appexLog("=== Xcode appex startTunnel begin pid=\(getpid()) ===")
        NSLog("[VpnTunnel] Xcode appex startTunnel begin (P1 Step A minimal)")
        // Step A：不设网络设置、不起 hev——只验证 NE spawn + 实例化 + 回调。
        // 让隧道连上（completionHandler(nil)），等 iOS 弹"允许"后应显示 connected。
        completionHandler(nil)
        appexLog("startTunnel completionHandler(nil) called")
    }

    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        appexLog("stopTunnel reason=\(reason.rawValue)")
        completionHandler()
    }

    public override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data("ok".utf8))
    }

    public override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    public override func wake() {}
}
