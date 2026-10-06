import Foundation

/// 桌面悬浮 HUD：主 App 用 root persona 拉起/关闭 TrollAgentHUD 独立二进制。
/// HUD 独立进程以无沙盒 + 系统 entitlements 创建全局系统窗口（放小女孩角色），
/// 由 HUD/sources/HUDApp.mm 管理 pid(/var/mobile/Library/Caches/trollagent.hud.pid)。
final class HUDManager {
    static let shared = HUDManager()
    private init() {}

    /// HUD 可执行路径：<主App bundle>/hud/TrollAgentHUD.app/TrollAgentHUD
    var hudBinaryPath: String? {
        guard let base = Bundle.main.bundlePath as NSString? else { return nil }
        let p = base.appendingPathComponent("hud/TrollAgentHUD.app/TrollAgentHUD")
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 是否在跑：HUDApp -check——进程存活返回 EXIT_FAILURE(1)，未在跑/无 pid 返回 EXIT_SUCCESS(0)
    var isRunning: Bool {
        guard let bin = hudBinaryPath else { return false }
        let (code, _) = InjectionManager.shared.spawnRoot(bin, args: ["-check"], timeout: 5)
        return code == 1
    }

    @discardableResult
    func start() -> Bool {
        guard let bin = hudBinaryPath else {
            NSLog("[HUD] binary not found — desktop floating window unavailable in this build")
            return false
        }
        let (code, out) = InjectionManager.shared.spawnRoot(bin, args: [], timeout: 15)
        if code != 0 { NSLog("[HUD] start failed code=\(code) out=\(out)") }
        return code == 0
    }

    @discardableResult
    func stop() -> Bool {
        guard let bin = hudBinaryPath else { return false }
        let (code, _) = InjectionManager.shared.spawnRoot(bin, args: ["-exit"], timeout: 15)
        return code == 0
    }
}
