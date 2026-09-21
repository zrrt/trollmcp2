import Foundation
import ZIPFoundation
import CISH

/// iSH-ARM64 引擎（TrollAgent 版）
/// - boot：首次调用时把 bundle 内 alpine-rootfs.zip 解压到 Documents，再 cish_boot 挂载 fakefs
/// - exec：每次调用在 guest 内 fork 独立 /bin/sh -c，串行执行（全局锁）
/// - 超时：cish_killpg 回收 guest 进程组，靠 exit_hook 通知管道收尾
/// - 会话 cwd：命令前缀 `cd '<cwd>' &&`；纯 cd 命令额外跑 pwd 更新会话目录
enum ISHEngine {
    enum BootState {
        case idle, booting, booted, failed(String)
    }

    private static let lock = NSLock()
    private static var state: BootState = .idle

    /// iSH 会话 cwd（guest 路径，与旧 ios_system 的 iOS 沙箱路径隔离）
    private static var guestCwd = "/root"

    private static var rootfsDir: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alpine-rootfs").path
    }
    private static var dataPath: String { rootfsDir + "/data" }

    static var isBooted: Bool {
        if case .booted = state { return true }
        return false
    }

    /// 当前 guest 会话目录（返回给 shell.exec 的 cwd 字段）
    static var cwd: String { guestCwd }

    /// v3.0.93: 重置会话目录到默认的 /workspace
    static func resetCwd() {
        lock.lock()
        defer { lock.unlock() }
        guestCwd = "/workspace"
    }

    /// 确保内核已 boot（首次解压 rootfs + 挂载）。线程安全，重复调用幂等。
    static func ensureBooted() -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .booted:
            return nil
        case .booting:
            return "[ish] 正在初始化内核，请稍后再试"
        case .failed(let msg):
            return "[ish] 内核初始化失败: \(msg)"
        case .idle:
            break
        }
        state = .booting

        // 1. rootfs 解压（首次）
        let fm = FileManager.default
        if !fm.fileExists(atPath: dataPath) {
            guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
                state = .failed("bundle 内缺少 alpine-rootfs.zip")
                return "[ish] 内核初始化失败: bundle 内缺少 alpine-rootfs.zip"
            }
            do {
                let parent = URL(fileURLWithPath: rootfsDir).deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.unzipItem(at: zipURL, to: parent)
            } catch {
                state = .failed("rootfs 解压失败: \(error.localizedDescription)")
                return "[ish] 内核初始化失败: rootfs 解压失败 \(error.localizedDescription)"
            }
            if !fm.fileExists(atPath: dataPath) {
                state = .failed("rootfs 解压后缺少 data 目录")
                return "[ish] 内核初始化失败: rootfs 解压后缺少 data 目录"
            }
        }

        // 2. cish_boot
        let rc = dataPath.withCString { cish_boot($0) }
        if rc != 0 {
            state = .failed("cish_boot rc=\(rc)")
            return "[ish] 内核初始化失败: cish_boot rc=\(rc)"
        }
        state = .booted

        // 3. 挂载工作区：在 rootfs 里创建 /workspace → iOS Documents/Workspace 的 symlink
        // 这样 iSH 终端里 cd /workspace 就能直接读写 TrollAgent 工作区文件，不沙盒隔离
        let workspaceLink = dataPath + "/workspace"
        // v3.0.91：symlink 目标用相对路径（iSH 只认识 rootfs 内路径），
        // /data/workspace → ../../Workspace 解析为 iSH 根目录下的 /Workspace，
        // 再由 iOS 层 symlink 指向真正的 Documents/Workspace
        let workspaceTarget = "../../Workspace"
        if !fm.fileExists(atPath: workspaceLink) {
            try? fm.createSymbolicLink(atPath: workspaceLink, withDestinationPath: workspaceTarget)
        }
        // 同时在 rootfs 根目录创建 /Workspace → Documents/Workspace 的 symlink（iOS 层绝对路径）
        let rootWorkspaceLink = rootfsDir + "/Workspace"
        let rootWorkspaceTarget = (rootfsDir as NSString).appendingPathComponent("../Workspace")
        if !fm.fileExists(atPath: rootWorkspaceLink) {
            try? fm.createSymbolicLink(atPath: rootWorkspaceLink, withDestinationPath: rootWorkspaceTarget)
        }
        // 默认 cwd 切到 /workspace
        guestCwd = "/workspace"

        ShellDiag.log("ISH boot ok data=\(dataPath) workspace symlink created")
        return nil
    }

    /// 执行命令。返回 (输出, 退出码, 是否超时)。未 boot 时自动尝试 boot，失败返回错误串。
    static func exec(_ command: String, timeout: TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) {
        if case .booted = state {} else {
            if let e = ensureBooted() { return (e, -1, false) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard case .booted = state else { return ("[ish] 内核未就绪", -1, false) }

        let cwd = guestCwd
        let tStart = Date()
        ShellDiag.log("ISH exec start cmd=\(command.prefix(80)) timeout=\(timeout) cwd=\(cwd)")

        // 纯 cd 命令：执行后额外取真实路径
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPureCd = trimmed.range(of: "^cd\\s+\\S+(\\s+.*)?$", options: .regularExpression) != nil
            && !trimmed.contains("&&") && !trimmed.contains(";")

        // v3.0.91：cd 失败不阻断命令执行（/workspace symlink 可能没创建成功）
        var fullCommand = "cd '\(shellQuote(cwd))' 2>/dev/null; \(command)"
        if isPureCd {
            fullCommand += " && pwd"
        }

        var outFds: [Int32] = [-1, -1]
        var errFds: [Int32] = [-1, -1]
        var notifyFds: [Int32] = [-1, -1]
        guard pipe(&outFds) == 0, pipe(&errFds) == 0, pipe(&notifyFds) == 0 else {
            ShellDiag.log("ISH exec pipe fail")
            return ("[ish] 管道创建失败", -1, false)
        }

        let argvBuf = buildCStringArray(["/bin/sh", "-c", fullCommand])
        let envpBuf = buildDefaultEnvp()
        let pid = argvBuf.withCString { av in
            envpBuf.withCString { ev in
                fullCommand.withCString { _ in
                    "/bin/sh".withCString { p in
                        cish_spawn(p, av, ev, 3, -1, outFds[1], errFds[1], notifyFds[1])
                    }
                }
            }
        }

        // 父进程关写端（guest 已 dup）
        close(outFds[1]); close(errFds[1]); close(notifyFds[1])

        if pid <= 0 {
            close(outFds[0]); close(errFds[0]); close(notifyFds[0])
            ShellDiag.log("ISH exec spawn fail pid=\(pid)")
            return ("[ish] 进程创建失败 rc=\(pid)", -1, false)
        }
        ShellDiag.log("ISH spawned pid=\(pid)")

        // 后台读 stdout/stderr + 退出通知
        let outBuf = NSMutableString()
        let errBuf = NSMutableString()
        let done = DispatchSemaphore(value: 0)
        var exitCode: Int32 = -1
        DispatchQueue.global(qos: .userInitiated).async {
            var out = Data()
            var b = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(outFds[0], &b, b.count)
                if n <= 0 { break }
                out.append(contentsOf: b[0..<n])
            }
            close(outFds[0])
            outBuf.append(String(decoding: out, as: UTF8.self))

            var err = Data()
            while true {
                let n = read(errFds[0], &b, b.count)
                if n <= 0 { break }
                err.append(contentsOf: b[0..<n])
            }
            close(errFds[0])
            errBuf.append(String(decoding: err, as: UTF8.self))

            // 退出通知：8 字节 (pid, code)
            var notify = Data()
            while notify.count < 8 {
                let n = read(notifyFds[0], &b, b.count)
                if n <= 0 { break }
                notify.append(contentsOf: b[0..<n])
            }
            close(notifyFds[0])
            if notify.count >= 8 {
                exitCode = notify.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
            }
            done.signal()
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // OpenMinis 语义：先 SIGTERM 让命令善后/落盘，1 秒后 SIGKILL 兜底
            _ = cish_killpg(pid, Int32(SIGTERM))
            _ = done.wait(timeout: .now() + 1)
            _ = cish_killpg(pid, Int32(SIGKILL))
            // 最多再等 3 秒收尾（guest 退出 → exit_hook 通知 → 读线程完成）
            _ = done.wait(timeout: .now() + 3)
            exitCode = 137
            ShellDiag.log("ISH TIMEOUT pid=\(pid)")
        }

        var stdout = outBuf as String
        let stderr = errBuf as String
        if !stderr.isEmpty {
            if !stdout.isEmpty && !stdout.hasSuffix("\n") { stdout += "\n" }
            stdout += stderr
        }

        // 纯 cd：从 pwd 输出解析新会话目录（guest 路径）
        if isPureCd {
            let lines = stdout.components(separatedBy: "\n").filter { $0.hasPrefix("/") }
            if let p = lines.last, p.hasPrefix("/") {
                guestCwd = p
            }
        }

        ShellDiag.log("ISH exec end elapsed=\(Int(Date().timeIntervalSince(tStart) * 1000))ms exit=\(exitCode) timedOut=\(timedOut) out=\(stdout.prefix(80))")
        return (stdout, exitCode, timedOut)
    }

    /// shell 单引号转义
    private static func shellQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// 构造 NUL 分隔 + 末尾双 NUL 的 argv 块
    private static func buildCStringArray(_ args: [String]) -> String {
        args.joined(separator: "\0") + "\0\0"
    }

    /// 内置默认环境（参考 OpenMinis envp）
    private static func buildDefaultEnvp() -> String {
        var vars: [String] = []
        vars.append("TERM=xterm-256color")
        vars.append("HOME=/root")
        vars.append("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        vars.append("LANG=C.UTF-8")
        vars.append("CHARSET=UTF-8")
        vars.append("ENV=/etc/profile")
        vars.append("OPENSSL_armcap=0")
        vars.append("NO_COLOR=1")
        vars.append("PYTHONDONTWRITEBYTECODE=1")
        // 设备时区（POSIX TZ，musl 兼容）
        let secs = TimeZone.current.secondsFromGMT()
        let hrs = secs / 3600
        let mins = abs(secs % 3600) / 60
        let tz = mins != 0 ? String(format: "LCL%+ld:%02ld", -hrs, mins) : String(format: "LCL%+ld", -hrs)
        vars.append("TZ=\(tz)")
        return vars.joined(separator: "\0") + "\0\0"
    }
}
