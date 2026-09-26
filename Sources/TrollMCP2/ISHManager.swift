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

        ShellDiag.log("ISH boot ok data=\(dataPath) (isolated rootfs, no file bridge)")
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

        // P5a v3.6.15: 代码层自动单向文件桥——Alpine 命令里引用 iOS 绝对路径时，系统自动
        // "原生读文件→经 guest stdin 管道喂原始字节→Alpine 侧 head -c N 写 /tmp/_bridge_N_name"并替换路径。
        // （v3.6.8 证伪 symlink 桥；v3.6.13 base64 内联超 iSH 命令长度，v3.6.14 改走 stdin 管道）
        let (bridged, bridgePrefix, bridgeStdin) = autoBridge(command)
        ShellDiag.log("ISH exec bridge: prefixEmpty=\(bridgePrefix.isEmpty) stdin=\(bridgeStdin.count)B execCmd=\(String(bridged.prefix(100)))")

        let cwd = guestCwd
        let tStart = Date()
        ShellDiag.log("ISH exec start cmd=\(command.prefix(80)) timeout=\(timeout) cwd=\(cwd)")

        // 纯 cd 命令：执行后额外取真实路径
        let trimmed = bridged.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPureCd = trimmed.range(of: "^cd\\s+\\S+(\\s+.*)?$", options: .regularExpression) != nil
            && !trimmed.contains("&&") && !trimmed.contains(";")

        // cd 失败不阻断命令执行（cwd 为真实 /root，但容错）
        var fullCommand = "cd '\(shellQuote(cwd))' 2>/dev/null; \(bridgePrefix)\(bridged)"
        if isPureCd {
            fullCommand += " && pwd"
        }

        var outFds: [Int32] = [-1, -1]
        var errFds: [Int32] = [-1, -1]
        var notifyFds: [Int32] = [-1, -1]
        var stdinFds: [Int32] = [-1, -1]
        guard pipe(&outFds) == 0, pipe(&errFds) == 0, pipe(&notifyFds) == 0 else {
            ShellDiag.log("ISH exec pipe fail")
            return ("[ish] pipe creation failed", -1, false)
        }
        // v3.6.14: 有桥文件时建 stdin 管道，guest stdin 接读端，host 写原始字节
        if !bridgeStdin.isEmpty {
            guard pipe(&stdinFds) == 0 else {
                ShellDiag.log("ISH exec stdin pipe fail")
                return ("[ish] stdin pipe creation failed", -1, false)
            }
        }

        let argvBuf = buildCStringArray(["/bin/sh", "-c", fullCommand])
        let envpBuf = buildDefaultEnvp()
        let pid = argvBuf.withCString { av in
            envpBuf.withCString { ev in
                fullCommand.withCString { _ in
                    "/bin/sh".withCString { p in
                        cish_spawn(p, av, ev, 3, stdinFds[0], outFds[1], errFds[1], notifyFds[1])
                    }
                }
            }
        }

        // 父进程关写端（guest 已 dup）
        close(outFds[1]); close(errFds[1]); close(notifyFds[1])

        if pid <= 0 {
            close(outFds[0]); close(errFds[0]); close(notifyFds[0])
            if stdinFds[0] >= 0 { close(stdinFds[0]); close(stdinFds[1]) }
            ShellDiag.log("ISH exec spawn fail pid=\(pid)")
            return ("[ish] process creation failed rc=\(pid)", -1, false)
        }
        ShellDiag.log("ISH spawned pid=\(pid)")

        // v3.6.14: host 侧把桥文件原始字节经 stdin 管道写进 guest（guest 侧 head -c N 消费）。
        // guest 已从读端 dup fd0；host 关闭读端，保留写端写数据后关闭。
        if !bridgeStdin.isEmpty, stdinFds[1] >= 0 {
            close(stdinFds[0])
            let expect = bridgeStdin.count
            ShellDiag.log("ISH bridge stdin: pipe created, expect \(expect)B")
            DispatchQueue.global(qos: .userInitiated).async {
                let wfd = stdinFds[1]
                var written = 0
                bridgeStdin.withUnsafeBytes { buf in
                    while written < buf.count {
                        let n = write(wfd, buf.baseAddress!.advanced(by: written), buf.count - written)
                        if n <= 0 { break }
                        written += n
                    }
                }
                close(wfd)
                ShellDiag.log("ISH bridge stdin: wrote \(written)/\(expect)B")
            }
        }

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

        // P5b v3.6.11: Alpine 命令向 /tmp 写了文件 → 附带 iOS 映射提示，agent 知道去哪取
        if bridged.range(of: "[>]+\\s*/tmp/", options: .regularExpression) != nil {
            if !stdout.isEmpty && !stdout.hasSuffix("\n") { stdout += "\n" }
            stdout += "[bridge] Alpine 写出的 /tmp/* 已同步回 iOS: Documents/alpine-rootfs/data/tmp/*"
        }

        ShellDiag.log("ISH exec end elapsed=\(Int(Date().timeIntervalSince(tStart) * 1000))ms exit=\(exitCode) timedOut=\(timedOut) out=\(stdout.prefix(80))")
        return (stdout, exitCode, timedOut)
    }

    /// P5a v3.6.14: 自动单向文件桥。识别 Alpine 命令里的 iOS 绝对路径 token，自动
    /// "原生读文件→经 guest stdin 管道喂原始字节→Alpine 侧 head -c N > /tmp/_bridge_N_name"并替换路径。
    /// 返回 (替换后命令, 需前置的建文件片段, 需经 stdin 管道写入的原始字节拼接)。
    /// 不用 base64 内联进命令串（v3.6.13 实测 122KB db 会超 iSH 命令长度，bridge 文件建不出来）。
    /// >maxBytes 的文件跳过（走显式协议，如 inject binary_symbols）。
    private static func autoBridge(_ command: String, maxBytes: Int = 2 * 1024 * 1024) -> (String, String, Data) {
        let fm = FileManager.default
        var result = command
        var prefix = ""
        var stdinData = Data()
        let prefixes = ["/var/mobile/", "/private/var/mobile/", "/System/", "/var/containers/"]
        let alt = prefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "(^|[\\s\"'=>(])(" + alt + "[^\\s\"'<>\\)]+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return (command, "", Data()) }
        let ns = result as NSString
        var seen = Set<String>()
        var pending: [(String, String)] = []   // (iosPath, bridgeFile)
        var counter = 0
        for m in re.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
            let raw = ns.substring(with: m.range(at: 2))
            guard !seen.contains(raw) else { continue }
            seen.insert(raw)
            let norm = ShellExecTool.normalizePath(raw)
            if norm.contains("/alpine-rootfs/") { continue }   // rootfs 自身落盘，Alpine 命令里无意义
            // 详细诊断：定位桥到底在哪一步断（命中/不存在/超限/读取失败）
            if !fm.fileExists(atPath: norm) {
                ShellDiag.log("autoBridge HIT: \(norm) 存在=false → 跳过")
                continue
            }
            guard let size = (try? fm.attributesOfItem(atPath: norm)[.size]) as? Int else {
                ShellDiag.log("autoBridge HIT: \(norm) stat失败 → 跳过")
                continue
            }
            if size <= 0 || size > maxBytes {
                ShellDiag.log("autoBridge HIT: \(norm) size=\(size)B 超限(>\(maxBytes)) → 跳过")
                continue
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: norm)) else {
                ShellDiag.log("autoBridge HIT: \(norm) size=\(size)B 读取失败 → 跳过")
                continue
            }
            counter += 1
            let safeName = URL(fileURLWithPath: raw).lastPathComponent
                .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            let bridgeFile = "/tmp/_bridge_\(counter)_" + (safeName.isEmpty ? "f" : safeName)
            // 原始字节经 stdin 管道喂给 guest，head -c N 精确写文件（命令串短，无长度限制）
            stdinData.append(data)
            prefix += "head -c \(data.count) > \(bridgeFile); "
            pending.append((raw, bridgeFile))
            ShellDiag.log("autoBridge OK: \(norm) → \(bridgeFile) (\(data.count)B)")
        }
        for (iosPath, bridgeFile) in pending.sorted(by: { $0.0.count > $1.0.count }) {
            result = result.replacingOccurrences(of: iosPath, with: bridgeFile)
        }
        if counter > 0 {
            ShellDiag.log("autoBridge: bridged \(counter) file(s), stdin=\(stdinData.count)B; files=[\(pending.map { $0.1 }.joined(separator: ","))]")
        } else if !seen.isEmpty {
            ShellDiag.log("autoBridge: 命中 \(seen.count) 个 iOS 路径但全部跳过(见上)")
        } else {
            ShellDiag.log("autoBridge: 未命中任何 iOS 路径 → 命令原样执行: \(String(command.prefix(80)))")
        }
        return (result, prefix, stdinData)
    }

    /// P3 按需补给：从 Alpine 命令输出检测缺失工具("X: not found" / "command not found")，
    /// 命中白名单则返回对应 apk 包名供自动安装；否则 nil。避免 agent 反复试探缺什么工具。
    static func missingToolPkg(_ output: String) -> String? {
        let map: [(cmd: String, pkg: String)] = [
            ("python3", "python3"), ("python", "python3"), ("pip", "py3-pip"),
            ("tar", "tar"), ("dpkg", "dpkg"), ("strings", "binutils"), ("hexdump", "binutils"),
            ("nm", "binutils"), ("objdump", "binutils"), ("readelf", "binutils"),
            ("size", "binutils"), ("addr2line", "binutils"),
            ("rabin2", "radare2"), ("r2", "radare2"), ("radare2", "radare2"),
            ("xxd", "xxd"), ("jq", "jq"), ("gdb", "gdb"),
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
        // v3.6.14 兜底：白名单外的任意工具名也直接返回该名作为包名（Alpine 绝大多数包名=命令名），
        // 让"AI 需要任何新工具"都能自动 apk add 并配合自动桥分析 iOS 文件，无需维护穷举清单。
        return inferPkgFromNotFound(output)
    }

    /// 从 "not found" 输出推断缺失工具的命令名（白名单兜底）。
    private static func inferPkgFromNotFound(_ output: String) -> String? {
        let patterns = [
            "(?:sh|/bin/sh|bash)?[\\s:]*([a-z0-9][a-z0-9._+-]*): (?:command )?not found",
            "command not found: ([a-z0-9][a-z0-9._+-]*)",
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = output as NSString
            for m in re.matches(in: output, options: [], range: NSRange(location: 0, length: ns.length)) {
                let cmd = ns.substring(with: m.range(at: 1))
                if isSafePkgName(cmd) { return cmd }
            }
        }
        return nil
    }

    /// 兜底安装的安全校验：只允许纯字母数字 . _ + - 的小写标识符，且非 shell 关键字/常见误报。
    private static func isSafePkgName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 40,
              s.first?.isLetter == true || s.first?.isNumber == true else { return false }
        let blocked = ["cd","fi","then","else","do","done","case","esac","test","true","false",
                       "exit","echo","printf","read","source","time","which","type","break","continue","pwd","ls","cat"]
        if blocked.contains(s) { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "+" || $0 == "-" }
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
