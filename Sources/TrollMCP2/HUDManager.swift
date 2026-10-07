import Foundation

/// 桌面悬浮 HUD：主 App 用 root persona 拉起/关闭 TrollAgentHUD 独立二进制。
/// HUD 独立进程以无沙盒 + 系统 entitlements 创建全局系统窗口（放小女孩角色），
/// 由 HUD/sources/HUDApp.mm 管理 pid(/var/mobile/Library/Caches/trollagent.hud.pid)。
final class HUDManager {
    static let shared = HUDManager()
    private init() {}

    /// 最近一次启动失败原因（供设置页 subtitle 直接展示，避免盲猜）
    var lastStartError: String?
    /// 最近一次启动日志写入 App 容器 Documents/hud.log（AI/终端可读）
    private let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/var/mobile")
        return docs.appendingPathComponent("hud.log")
    }()

    /// HUD 可执行路径：<主App bundle>/hud/TrollAgentHUD.app/TrollAgentHUD
    var hudBinaryPath: String? {
        let base = Bundle.main.bundlePath
        let p = base + "/hud/TrollAgentHUD.app/TrollAgentHUD"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 主 App bundle 路径（供诊断显示）
    var bundlePath: String { Bundle.main.bundlePath }

    private func appendLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8) ?? Data()); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logURL, options: .atomic)
        }
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
            lastStartError = "HUD 二进制缺失：\(bundlePath)/hud/TrollAgentHUD.app/TrollAgentHUD 不存在"
            appendLog("start FAIL: binary not found at \(bundlePath)/hud/")
            return false
        }
        appendLog("start: launching \(bin)")
        let (code, out) = InjectionManager.shared.spawnRoot(bin, args: [], timeout: 15)
        if code != 0 {
            lastStartError = "拉起失败 errno=\(code) out=\(out)"
            appendLog("start FAIL: spawn errno=\(code) out=\(out)")
            return false
        }
        lastStartError = nil
        appendLog("start OK")
        return true
    }

    @discardableResult
    func stop() -> Bool {
        guard let bin = hudBinaryPath else { return false }
        let (code, _) = InjectionManager.shared.spawnRoot(bin, args: ["-exit"], timeout: 15)
        appendLog("stop: code=\(code)")
        return code == 0
    }
}
