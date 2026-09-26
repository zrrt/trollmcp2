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

    /// v3.6.8: 重置会话目录到真实存在的 /root（Alpine 纯隔离，无 /workspace 桥接）
    static func resetCwd() {
        lock.lock()
        defer { lock.unlock() }
        guestCwd = "/root"
    }

    /// 确保内核已 boot（首次解压 rootfs + 挂载）。线程安全，重复调用幂等。
    static func ensureBooted() -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .booted:
            return nil
        case .booting:
            return "[ish] kernel initializing, try again later"
        case .failed(let msg):
            return "[ish] kernel init failed: \(msg)"
        case .idle:
            break
        }
        state = .booting

        // 1. rootfs 解压（首次）
        let fm = FileManager.default
        if !fm.fileExists(atPath: dataPath) {
            guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
                state = .failed("alpine-rootfs.zip missing from bundle")
                return "[ish] kernel init failed: alpine-rootfs.zip missing from bundle"
            }
            do {
                let parent = URL(fileURLWithPath: rootfsDir).deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.unzipItem(at: zipURL, to: parent)
            } catch {
                state = .failed("rootfs extraction failed: \(error.localizedDescription)")
                return "[ish] kernel init failed: rootfs extraction failed \(error.localizedDescription)"
            }
            if !fm.fileExists(atPath: dataPath) {
                state = .failed("rootfs 解压后缺少 data 目录")
                return "[ish] 内核初始化失败: rootfs 解压后缺少 data 目录"
            }
        }

        // 2. cish_boot（v3.6.8: 实测确认 fakefs 挂载时不解析跨 iOS 路径的 symlink，
        //    Alpine 为纯隔离 rootfs，不再预建 /workspace、/ios 桥接）
        let rc = dataPath.withCString { cish_boot($0) }
        if rc != 0 {
            state = .failed("cish_boot rc=\(rc)")
            return "[ish] 内核初始化失败: cish_boot rc=\(rc)"
        }
        state = .booted

        // 3. 默认 cwd 为真实存在的 /root（避免名义 /workspace 误导）
        guestCwd = "/root"

        ShellDiag.log("ISH boot ok data=\(dataPath) bridge links pre-created")
        return nil
    }

    /// 执行命令。返回 (输出, 退出码, 是否超时)。未 boot 时自动尝试 boot，失败返回错误串。
    /// v3.6.8: Alpine 为纯隔离 rootfs(fakefs 不解析跨 iOS 的 symlink)，不做路径改写；
    /// 读 iOS 文件走原生 shell，Alpine 工具链需 iOS 文件时先 cp 进 rootfs(/tmp)。
    static func exec(_ command: String, timeout: TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) {
        if case .booted = state {} else {
            if let e = ensureBooted() { return (e, -1, false) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard case .booted = state else { return ("[ish] kernel not ready", -1, false) }

        // 说明(v3.6.8): 实测确认 iSH fakefs 挂载时不解析跨 iOS 路径的 symlink——
        // Alpine 是纯隔离 rootfs, /workspace 与 /ios/* 桥接目录在 guest 里不可见。
        // 因此不再做任何路径改写(避免把 Alpine 内部真实 /var/mobile 误改成不存在的 /ios/mobile)。
        // 读 iOS 文件走原生 shell; Alpine 工具链需 iOS 文件时先 cp 进 rootfs(/tmp)。见提示词。
        let bridged = command

        let cwd = guestCwd
        let tStart = Date()
        ShellDiag.log("ISH exec start cmd=\(command.prefix(80)) timeout=\(timeout) cwd=\(cwd)")

        // 纯 cd 命令：执行后额外取真实路径
        let trimmed = bridged.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPureCd = trimmed.range(of: "^cd\\s+\\S+(\\s+.*)?$", options: .regularExpression) != nil
            && !trimmed.contains("&&") && !trimmed.contains(";")

        // cd 失败不阻断命令执行（cwd 为真实 /root，但容错）
        var fullCommand = "cd '\(shellQuote(cwd))' 2>/dev/null; \(bridged)"
        if isPureCd {
            fullCommand += " && pwd"
        }

        var outFds: [Int32] = [-1, -1]
        var errFds: [Int32] = [-1, -1]
        var notifyFds: [Int32] = [-1, -1]
        guard pipe(&outFds) == 0, pipe(&errFds) == 0, pipe(&notifyFds) == 0 else {
            ShellDiag.log("ISH exec pipe fail")
            return ("[ish] pipe creation failed", -1, false)
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
            return ("[ish] process creation failed rc=\(pid)", -1, false)
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

    /// P3 按需补给：从 Alpine 命令输出检测缺失工具("X: not found" / "command not found")，
    /// 命中白名单则返回对应 apk 包名供自动安装；否则 nil。避免 agent 反复试探缺什么工具。
    static func missingToolPkg(_ output: String) -> String? {
        let map: [(cmd: String, pkg: String)] = [
            ("python3", "python3"), ("python", "python3"), ("pip", "py3-pip"),
            ("tar", "tar"), ("dpkg", "dpkg"), ("strings", "binutils"), ("hexdump", "binutils"),
            ("git", "git"), ("wget", "wget"), ("make", "make"), ("cmake", "cmake"),
            ("gcc", "build-base"), ("clang", "clang"), ("openssl", "openssl"),
            ("unzip", "unzip"), ("sqlite3", "sqlite3"),
        ]
        for (cmd, pkg) in map {
            if output.contains("\(cmd): not found")
                || output.contains("\(cmd): command not found")
                || output.contains("command not found: \(cmd)") {
                return pkg
            }
        }
        return nil
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
