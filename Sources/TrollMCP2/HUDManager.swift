import Foundation
import Darwin

/// 桌面悬浮 HUD 进程 pid 文件（HUDMainStart 写入）
private let PID_PATH = "/var/mobile/Library/Caches/trollagent.hud.pid"
/// start() 诊断日志（写到 /tmp，8790 ios_native 可直接 cat 读，确证 start 执行到哪步）
private let TMP_LOG = "/tmp/hud.start.log"

/// v6.0.4：persona 99 提权所需 C 函数声明（@_silgen_name 只能用于顶层全局函数，
/// 不能放类里实例方法——之前放类里导致 Build IPA 编译失败）。
#if !targetEnvironment(simulator)
// v6.0.4: posix_spawnattr_t 在 iOS 是 void*(=UnsafeMutableRawPointer)，&attr 是
// UnsafeMutablePointer<UnsafeMutableRawPointer>。声明参数用不带外层 Optional 的
// UnsafeMutablePointer<posix_spawnattr_t>(展开即 UnsafeMutablePointer<UnsafeMutableRawPointer>)。
@_silgen_name("posix_spawnattr_set_persona_np")
func _troll_persona_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t>, _ persona: uid_t, _ flags: UInt32) -> Int32
@_silgen_name("posix_spawnattr_set_persona_uid_np")
func _troll_persona_uid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t>, _ uid: uid_t) -> Int32
@_silgen_name("posix_spawnattr_set_persona_gid_np")
func _troll_persona_gid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t>, _ gid: gid_t) -> Int32
#endif

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

    /// posix_spawn 拉起且不等待/不超时——HUD 是常驻进程(runloop 不退出)，
    /// 用带 timeout 的 spawn 会在 15s 后 SIGKILL 把 HUD 杀掉(桌面悬浮窗刚建就消失)。
    /// detach：spawn 后立即返回，HUD 以独立进程常驻(父进程被 launchd 收养)。
    /// v6.0.4：改回 persona 99 提权(uid/gid 0)跑 HUD——TrollSpeed/TheBall 正解。
    /// 之前不提权 detach 让 HUD 以 mobile sandbox 身份跑，HUDMainStart 的
    /// UIApplicationInitialize/__completeAndRunAsPlugin 在 sandbox 下崩(step=enter 都没落盘)。
    /// 主 App 已有 platform-application + persona-mgmt entitlements，persona 99 不再报 106。
    private static let POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE: UInt32 = 1
    private func spawnDetached(_ path: String, args: [String]) -> Bool {
        var attr: posix_spawnattr_t = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        #if !targetEnvironment(simulator)
        _troll_persona_np(&attr, 99, HUDManager.POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)
        _troll_persona_uid_np(&attr, 0 as uid_t)
        _troll_persona_gid_np(&attr, 0 as gid_t)
        #endif
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)] + args.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, nil, &attr, &argv, nil)
        return status == 0
    }
    /// 最近一次启动日志写入 App 容器 Documents/hud.log + /var/mobile/Documents/hud.log
    /// （后者在 /var/mobile/Documents，8790 shell.exec 可直接 cat 读，便于 AI 连真机诊断）
    private let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/var/mobile")
        return docs.appendingPathComponent("hud.log")
    }()
    private let sysLogURL = URL(fileURLWithPath: "/var/mobile/Documents/hud.log")

    /// HUD 可执行路径：优先独立 HUD 二进制（Resources/hud/TrollAgentHUD.app，TrollStore 随主 App 重签，
    /// 签名有效 AMFI 放行——TrollSpeed 正解）；兜底主可执行 -hud（旧方案，主可执行二次 exec 可能被 AMFI 拒）
    var hudBinaryPath: String? {
        let hudApp = Bundle.main.bundlePath + "/hud/TrollAgentHUD.app/TrollAgentHUD"
        if FileManager.default.fileExists(atPath: hudApp) { return hudApp }
        let p = Bundle.main.executablePath ?? ""
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 主 App bundle 路径（供诊断显示）
    var bundlePath: String { Bundle.main.bundlePath }

    private func appendLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let data = line.data(using: .utf8) ?? Data()
        // 主日志写 App Documents + /var/mobile/Documents
        for url in [logURL, sysLogURL] {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        // 诊断副本写 /tmp（8790 ios_native 可直接 cat 读，确证 start 执行到哪步）
        let tmpURL = URL(fileURLWithPath: TMP_LOG)
        if let h = try? FileHandle(forWritingTo: tmpURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: tmpURL, options: .atomic)
        }
    }

    /// v4.5.9：launchctl 真实路径探测——iOS 各版本位置不一(/usr/bin 或 /usr/sbin /bin /sbin)。
    /// 逐路径探测，避免写死 /usr/bin 在部分 iOS 上 ENOENT。找不到返回 nil（subtitle 明确提示）。
    private var launchctlBinary: String? {
        for p in ["/usr/bin/launchctl", "/usr/sbin/launchctl", "/bin/launchctl", "/sbin/launchctl"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// 是否在跑：直接读 pid 文件 + kill(pid,0) 检查进程存活。
    /// （不再用 spawnRoot(-check)：那是提权 persona 99，iOS16+TrollStore 下 errno 106，判断不可靠）
    var isRunning: Bool {
        guard let pidStr = try? String(contentsOfFile: PID_PATH, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
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
        // v4.5.9：launchctl 路径探测——写死 /usr/bin 在部分 iOS 上 ENOENT 会误导诊断
        if let lctl = launchctlBinary {
            if writeDaemonPlist(bin: bin) {
                let (code, out) = InjectionManager.shared.spawnRoot(lctl, args: ["load", daemonPlistPath], timeout: 15)
                if code == 0 {
                    lastStartError = nil
                    appendLog("start OK via launchctl load (\(lctl))")
                    return true
                }
                appendLog("launchctl load errno=\(code) out=\(out) (\(lctl))——回退 posix_spawn")
            }
        } else {
            lastStartError = "launchctl 二进制未找到（/usr/bin /usr/sbin /bin /sbin 均无）"
            appendLog("start: launchctl not found in standard paths——直接 posix_spawn")
        }

        // 方案 B(TheBall)：不提权 posix_spawn detach 拉起 HUD（mobile 身份，常驻不 timeout）
        // ——避开 persona 99 的 errno 106；detach 不 waitpid 让 HUD 长期存活，不触发 15s SIGKILL。
        // HUD 显示全局窗口不靠 root，靠 accessibility-window-hosting entitlement（主可执行已带）。
        if !spawnDetached(bin, args: ["-hud"]) {
            lastStartError = "拉起失败 (posix_spawn detach)"
            appendLog("start FAIL: spawnDetached")
            return false
        }
        lastStartError = nil
        appendLog("start OK (posix_spawn detach 不提权, 常驻)")
        return true
    }

    @discardableResult
    func stop() -> Bool {
        // 主路径：launchctl unload
        if FileManager.default.fileExists(atPath: daemonPlistPath), let lctl = launchctlBinary {
            let (code, out) = InjectionManager.shared.spawnRoot(lctl, args: ["unload", daemonPlistPath], timeout: 15)
            appendLog("stop: launchctl unload code=\(code) out=\(out)")
            if code == 0 { return true }
        }
        guard let bin = hudBinaryPath else { return false }
        let (code, _) = InjectionManager.shared.spawn(bin, args: ["-exit"], timeout: 15)
        appendLog("stop: posix_spawn -exit code=\(code)")
        return code == 0
    }
}
