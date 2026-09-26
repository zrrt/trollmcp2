// TrustEnabler：起 VPN 前的"信任注入"决策与调度层（v3.5.26）
//
// 统一架构：TrollAgent 一套代码跨 iOS 16.x / 17.x。
// 唯一分叉点 = 如何让假签名的 VpnTunnel.appex 通过 NECP 的 CS_VALID 校验。
//
// 路径① .kfdInject  —— iOS 16.x 非越狱：posix_spawn 调 kfd_helper（puaf_landa）
//                       临时拿内核读写 → 把扩展 cdhash 写进内核 trust cache → 免越狱不留痕
// 路径② .jailbreak  —— iOS 17.x 越狱(Dopamine/palera1n)：jailbreakd 已 hook csops+necp，
//                       CS_VALID 常驻放行 → 直接起 packet-tunnel，无需自备注入
// 路径③ .fallback   —— 都不满足：回退本地代理(127.0.0.1:18180)，抓 HTTP
//
// 统一出口：三种路径最终都调用同一个 VpnManager.startVpnViaRegisteredManager。

import Foundation
import UIKit
import Darwin

enum TrustPath {
    case kfdInject     // iOS 16.x 非越狱 + 有 kfd
    case jailbreak     // 越狱（Dopamine / palera1n），jailbreakd 已常驻
    case fallback      // 都不满足 → 本地代理
}

enum TrustEnabler {

    // MARK: - 探测

    /// 是否越狱（rootless 看 /var/jb；rootful 看 Cydia 等）
    static var isJailbroken: Bool {
        let checks = [
            "/var/jb",                       // Dopamine / palera1n rootless
            "/var/jb/basebin/jailbreakd",
            "/Applications/Cydia.app",
            "/usr/libexec/cydia",
            "/Library/MobileSubstrate/MobileSubstrate.dylib"
        ]
        for p in checks where FileManager.default.fileExists(atPath: p) { return true }
        return false
    }

    /// 当前 iOS 主/次版本，如 16.3 → (16, 3)
    static var iosVersion: (major: Int, minor: Int) {
        let v = UIDevice.current.systemVersion.split(separator: ".")
        let m = Int(v.first ?? "0") ?? 0
        let n = Int(v.count > 1 ? v[1] : "0") ?? 0
        return (m, n)
    }

    /// kfd（puaf_landa）可用的固件区间：iOS 15.5 – 16.6.1（16.7 起被修）
    static var kfdAvailable: Bool {
        let (m, n) = iosVersion
        if m == 15 { return n >= 5 }
        if m == 16 { return n <= 6 }   // 16.0–16.6
        return false
    }

    /// 决定当前设备走哪条信任注入路径
    static func resolvePath() -> TrustPath {
        if isJailbroken { return .jailbreak }
        if kfdAvailable { return .kfdInject }
        return .fallback
    }

    // MARK: - 注入

    /// 起 VPN 前调用：按路径做信任注入。completion(true) = 可以继续起 VPN。
    static func injectIfNeeded(completion: @escaping (Bool) -> Void) {
        switch resolvePath() {
        case .jailbreak:
            // jailbreakd 已常驻 hook csops+necp，CS_VALID 已放行，无需自备注入
            // v3.5.27: 上述假设不成立——VPN 扩展 cdhash 必须显式写进系统信任缓存，
            // 用 libjailbreak 的 SystemWide 域 XPC（非 root）让 jailbreakd 信任该文件。
            guard let appex = vpnTunnelBinaryPath() else { completion(false); return }
            let ok = trustFileViaJailbreakd(appex)
            DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.8 : 0)) {
                completion(ok)
            }
        case .kfdInject:
            guard let helper = kfdHelperPath() else { completion(false); return }
            guard let appex = vpnTunnelBinaryPath() else { completion(false); return }
            // kfd 提权(10–60s)放后台执行，避免 waitpid 阻塞主线程导致按钮"点了没反应"
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = spawn(helper, args: [appex])
                DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.8 : 0)) {
                    completion(ok)
                }
            }
        case .fallback:
            // 无法注入 → 让上层回退本地代理
            completion(false)
        }
    }

    // MARK: - 路径

    /// kfd_helper 二进制：build-ipa.sh 把 Resources/bin 复制到 App bundle 的 bin/
    static func kfdHelperPath() -> String? {
        let candidates = [
            Bundle.main.bundlePath + "/bin/kfd_helper",
            Bundle.main.bundlePath + "/Resources/bin/kfd_helper",
            Bundle.main.bundlePath + "/kfd_helper"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// VpnTunnel.appex 的 Mach-O 二进制路径
    static func vpnTunnelBinaryPath() -> String? {
        let p = Bundle.main.bundlePath + "/PlugIns/VpnTunnel.appex/VpnTunnel"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    // MARK: - posix_spawn

    /// 用 posix_spawn 启动一个 helper（kfd_helper 免 root，漏洞自提权）。
    /// kfd_helper 自身在 main 里 freopen 把 stderr 重定向到
    /// /var/mobile/Documents/kfd_helper.log —— 每步诊断(kopen/patchfind/kalloc)都在这。
    /// 带 90s 超时（kfd kopen 提权可能 10–60s；超时杀掉避免 UI 永久卡死）。
    private static func spawn(_ path: String, args: [String]) -> Bool {
        var pid: pid_t = 0
        var argv = args.map { $0.withCString { strdup($0) } }
        argv.insert(path.withCString { strdup($0) }, at: 0)
        argv.append(nil)
        var envp = ["HOME=/var/mobile", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"].map { $0.withCString { strdup($0) } }
        envp.append(nil)

        var rc: Int32 = -1
        path.withCString { cpath in
            argv.withUnsafeBufferPointer { ab in
                envp.withUnsafeBufferPointer { eb in
                    rc = posix_spawn(&pid, cpath, nil, nil, ab.baseAddress, eb.baseAddress)
                }
            }
        }
        argv.forEach { free($0) }
        envp.forEach { free($0) }

        if rc != 0 {
            NSLog("TrustEnabler: spawn %@ failed rc=%d", path, rc)
            return false
        }
        var status: Int32 = 0
        let deadline = DispatchTime.now() + .seconds(90)
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if DispatchTime.now() > deadline {
                kill(pid, SIGKILL); waitpid(pid, &status, 0)
                NSLog("TrustEnabler: kfd_helper 超时被终止 — 看 /var/mobile/Documents/kfd_helper.log 定位卡点")
                return false
            }
            usleep(200_000)
        }
        // WEXITSTATUS = (status >> 8) & 0xff
        return ((status >> 8) & 0xff) == 0
    }

    // MARK: - 越狱信任缓存注入（Dopamine / palera1n rootless）

    /// 用 libjailbreak 的 SystemWide 域 XPC（JBS_SYSTEMWIDE_TRUST_FILE）让 jailbreakd
    /// 把给定文件（VpnTunnel.appex）的全部 cdhash 加入系统信任缓存。
    /// - 非 root：Dopamine 越狱显示状态下 SystemWide 域对任何进程可达。
    /// - 返回值 true = jailbreakd 已把扩展加入信任缓存，可继续起 VPN。
    static func trustFileViaJailbreakd(_ path: String) -> Bool {
        // Dopamine 把 libjailbreak.dylib 放在 rootless 前缀 /var/jb/usr/lib/
        let libCandidates = [
            "/var/jb/usr/lib/libjailbreak.dylib",
            "/usr/lib/libjailbreak.dylib",
        ]
        for lib in libCandidates where FileManager.default.fileExists(atPath: lib) {
            guard let handle = dlopen(lib, RTLD_NOW) else {
                NSLog("TrustEnabler: dlopen(%@) failed", lib)
                continue
            }
            guard let sym = dlsym(handle, "jbclient_trust_file_by_path") else {
                NSLog("TrustEnabler: dlsym(jbclient_trust_file_by_path) failed in %@", lib)
                continue
            }
            typealias TrustFileFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
            let fn = unsafeBitCast(sym, to: TrustFileFn.self)
            let rc = path.withCString { fn($0) }
            NSLog("TrustEnabler: jbclient_trust_file_by_path(%@)=%d", path, rc)
            return rc == 0
        }
        NSLog("TrustEnabler: libjailbreak.dylib not found — 越狱信任注入不可用")
        return false
    }
}
