import Foundation

/// 桌面悬浮 HUD：单可执行双模式（TrollSpeed 正解）。
/// 主 App 可执行（TrollStore 有效签名）由 HUDManager 以 root persona 拉起，argv 带
/// -hud 进悬浮模式——复用主可执行的有效签名，AMFI 放行（独立二进制假签名被 106/109 拒的根因已消除）。
/// HUD 用无沙盒 + 系统 entitlements 创建全局系统窗口（放小女孩角色），
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

    /// HUD 可执行路径：主 App 可执行本身（单可执行双模式，-hud 进悬浮）
    var hudBinaryPath: String? {
        let p = Bundle.main.executablePath ?? ""
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

    /// 是否在跑：主可执行 -check——进程存活返回 EXIT_FAILURE(1)，未在跑/无 pid 返回 EXIT_SUCCESS(0)
    var isRunning: Bool {
        guard let bin = hudBinaryPath else { return false }
        let (code, _) = InjectionManager.shared.spawnRoot(bin, args: ["-check"], timeout: 5)
        return code == 1
    }

    /// LaunchDaemon plist：TrollSpeed 主路径靠 launchctl load 拉起（launchd 以 root+App 类型 spawn，
    /// AMFI 放行）。posix_spawn persona 只是 plist 缺失时的兜底，直接走会 errno 106。
    /// 写到 App Documents 容器（100% 可写；launchctl load 支持任意路径，launchd 以 root 读）。
    private var daemonPlistPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/var/mobile")
        return docs.appendingPathComponent("hudservices.plist").path
    }
    private let daemonLabel = "com.trollagent.hudservices"

    private func writeDaemonPlist(bin: String) -> Bool {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>EnablePressuredExit</key>
        \t<false/>
        \t<key>EnableTransactions</key>
        \t<false/>
        \t<key>EnvironmentVariables</key>
        \t<dict>
        \t\t<key>DISABLE_TWEAKS</key>
        \t\t<string>1</string>
        \t</dict>
        \t<key>GroupName</key>
        \t<string>wheel</string>
        \t<key>HighPriorityIO</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>Label</key>
        \t<string>\(daemonLabel)</string>
        \t<key>POSIXSpawnType</key>
        \t<string>App</string>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(bin)</string>
        \t\t<string>-hud</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>ThrottleInterval</key>
        \t<integer>5</integer>
        \t<key>UserName</key>
        \t<string>root</string>
        \t<key>_AdditionalProperties</key>
        \t<dict>
        \t\t<key>RunningBoard</key>
        \t\t<dict>
        \t\t\t<key>Managed</key>
        \t\t\t<false/>
        \t\t\t<key>Reported</key>
        \t\t\t<false/>
        \t\t</dict>
        \t</dict>
        </dict>
        </plist>
        """
        do {
            try xml.data(using: .utf8)?.write(to: URL(fileURLWithPath: daemonPlistPath), options: .atomic)
            appendLog("wrote daemon plist \(daemonPlistPath)")
            return true
        } catch {
            appendLog("write daemon plist FAIL: \(error)")
            return false
        }
    }

    @discardableResult
    func start() -> Bool {
        guard let bin = hudBinaryPath else {
            lastStartError = "主可执行缺失：\(bundlePath)"
            appendLog("start FAIL: main executable not found at \(bundlePath)")
            return false
        }
        appendLog("start: launching \(bin) -hud")

        // 主路径：写 LaunchDaemon plist + launchctl load（launchd 以 root+App 拉起，AMFI 放行）
        if writeDaemonPlist(bin: bin) {
            let (code, out) = InjectionManager.shared.spawnRoot("/usr/bin/launchctl", args: ["load", daemonPlistPath], timeout: 15)
            if code == 0 {
                lastStartError = nil
                appendLog("start OK via launchctl load")
                return true
            }
            appendLog("launchctl load errno=\(code) out=\(out)——回退 posix_spawn")
        }

        // 兜底：posix_spawn persona 99（TrollSpeed 仅 plist 缺失时用；可能 106）
        let (code, out) = InjectionManager.shared.spawnRoot(bin, args: ["-hud"], timeout: 15)
        if code != 0 {
            lastStartError = "拉起失败 errno=\(code) out=\(out)"
            appendLog("start FAIL: spawn errno=\(code) out=\(out)")
            return false
        }
        lastStartError = nil
        appendLog("start OK (posix_spawn fallback)")
        return true
    }

    @discardableResult
    func stop() -> Bool {
        // 主路径：launchctl unload
        if FileManager.default.fileExists(atPath: daemonPlistPath) {
            let (code, out) = InjectionManager.shared.spawnRoot("/usr/bin/launchctl", args: ["unload", daemonPlistPath], timeout: 15)
            appendLog("stop: launchctl unload code=\(code) out=\(out)")
            if code == 0 { return true }
        }
        guard let bin = hudBinaryPath else { return false }
        let (code, _) = InjectionManager.shared.spawnRoot(bin, args: ["-exit"], timeout: 15)
        appendLog("stop: posix_spawn -exit code=\(code)")
        return code == 0
    }
}
