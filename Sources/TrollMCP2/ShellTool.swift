import Foundation
import UIKit
import Darwin

/// 终端会话管理（单例，记住当前工作目录）
final class ShellSession {
    static let shared = ShellSession()
    private init() {}
    
    var currentDir: String = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Workspace").path
}

/// ios_system 动态加载
/// v3.0.33 重写 exec：
///   - 修复 v3.0.32 死锁：Foundation Pipe 写端句柄未关闭，readDataToEndOfFile 永远等不到 EOF，shell.exec 全部卡死
///   - 改回 C 风格 pipe：dup2 后立刻 close(writeFD)，命令结束后读端正常收 EOF
///   - 同时捕获 stdout + stderr
///   - 真实超时：超时后调 ios_kill 终止卡住的命令，调用方不被阻塞
///   - 返回真实退出码（ios_system 返回值）
/// v3.0.34 补全命令表：
///   - 打包 commandDictionary.plist（库名改 @executable_path 绝对定位）+ 扁平 framework（ios_system/files/shell/text/tar/awk）
///   - 加载后调用 initializeEnvironment()（设置 PATH/APPDIR，让 $APPDIR/bin 的外部工具可用）
///   - 预加载同伴框架，保证依赖解析
enum IOSSystem {
    static var handle: UnsafeMutableRawPointer?
    
    static func load() {
        guard handle == nil else { return }
        guard let fwPath = Bundle.main.path(forResource: "ios_system", ofType: nil, inDirectory: "ios_system.framework") else {
            print("ios_system.framework not found")
            return
        }
        handle = dlopen(fwPath, RTLD_NOW)
        if handle == nil {
            print("dlopen failed: \(String(cString: dlerror()))")
            return
        }
        // 初始化环境（PATH/APPDIR 等），否则外部工具找不到
        if let envPtr = dlsym(handle, "initializeEnvironment") {
            typealias env_func = @convention(c) () -> Void
            let envFn = unsafeBitCast(envPtr, to: env_func.self)
            envFn()
        }
        // 预加载同伴框架（绝对路径，RTLD_GLOBAL），保证 ios_system 内部按名 dlopen 时依赖已就绪
        let companions = ["files.framework/files", "shell.framework/shell", "text.framework/text", "tar.framework/tar", "awk.framework/awk"]
        for c in companions {
            let p = Bundle.main.bundlePath + "/" + c
            _ = dlopen(p, RTLD_NOW | RTLD_GLOBAL)
        }
    }
    
    /// 执行命令（v3.0.35：posix_spawn 独立 helper 进程，可被 SIGKILL 回收）。
    /// 返回 (输出, 退出码, 是否超时)
    static func exec(_ command: String, timeout: TimeInterval = 30) -> (output: String, exitCode: Int32, timedOut: Bool) {
        load()
        guard let helper = Bundle.main.path(forResource: "shellhelper", ofType: nil) else {
            return ("[shell] shellhelper 未找到", -1, false)
        }
        let appDir = Bundle.main.bundlePath
        let cwd = ShellSession.shared.currentDir
        let tStart = Date()
        ShellDiag.log("exec start cmd=\(command.prefix(80)) timeout=\(timeout) cwd=\(cwd)")

        var outFds: [Int32] = [-1, -1]
        var repFds: [Int32] = [-1, -1]
        guard pipe(&outFds) == 0, pipe(&repFds) == 0 else {
            ShellDiag.log("exec pipe fail")
            return ("[shell] pipe 创建失败", -1, false)
        }

        // 子进程放入独立进程组，超时后 kill(-pid) 连子孙一起清
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outFds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outFds[1], STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, repFds[1], 3)
        posix_spawn_file_actions_addclose(&actions, outFds[0])
        posix_spawn_file_actions_addclose(&actions, repFds[0])
        posix_spawn_file_actions_addclose(&actions, outFds[1])
        posix_spawn_file_actions_addclose(&actions, repFds[1])

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), strdup(cwd), strdup(command), strdup(appDir), nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, helper, &actions, &attr, argv, environ)
        // 清理
        argv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        // 父进程关写端，读端才能收 EOF
        close(outFds[1])
        close(repFds[1])

        guard rc == 0 else {
            close(outFds[0])
            close(repFds[0])
            ShellDiag.log("exec spawn fail rc=\(rc)")
            return ("[shell] posix_spawn 失败 rc=\(rc)", -1, false)
        }
        ShellDiag.log("exec spawned pid=\(pid)")

        // 后台线程读输出与报告，主线程等带超时
        let outputBuf = NSMutableString()
        var reportBuf = NSMutableString()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var out = Data()
            var b = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(outFds[0], &b, b.count)
                if n <= 0 { break }
                out.append(contentsOf: b[0..<n])
            }
            close(outFds[0])
            outputBuf.append(String(decoding: out, as: UTF8.self))

            var rep = Data()
            while true {
                let n = read(repFds[0], &b, b.count)
                if n <= 0 { break }
                rep.append(contentsOf: b[0..<n])
            }
            close(repFds[0])
            reportBuf = NSMutableString(string: String(decoding: rep, as: UTF8.self))
            done.signal()
        }

        var timedOut = false
        var exitCode: Int32 = -1
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // 杀整个进程组，回收卡死命令（阻塞 syscall 也能被 SIGKILL 打断）
            let k1 = kill(-pid, SIGKILL)
            let k2 = kill(pid, SIGKILL)
            // 等 2 秒让后台线程收完 EOF；若进程还活着再补一刀
            _ = done.wait(timeout: .now() + 2)
            if kill(pid, 0) == 0 || errno == 0 {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
            }
            exitCode = 137
            ShellDiag.log("exec TIMEOUT pid=\(pid) k1=\(k1) k2=\(k2) still=\(kill(pid, 0)) errno=\(errno)")
        } else {
            // 解析报告：EXIT:<code>\nCWD:<path>\n
            let text = reportBuf as String
            for line in text.split(separator: "\n") {
                if line.hasPrefix("EXIT:") {
                    exitCode = Int32(line.dropFirst(5)) ?? -1
                } else if line.hasPrefix("CWD:") {
                    let p = String(line.dropFirst(4))
                    if p.hasPrefix("/") { ShellSession.shared.currentDir = p }
                }
            }
        }
        ShellDiag.log("exec end elapsed=\(Int(Date().timeIntervalSince(tStart) * 1000))ms exit=\(exitCode) timedOut=\(timedOut)")
        return (outputBuf as String, exitCode, timedOut)
    }
}

/// v3.0.36：shell 诊断日志（Documents/Workspace/shell-diag.log），追查超时/卡死真相
enum ShellDiag {
    private static let lock = NSLock()
    private static var path: String = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace/shell-diag.log").path
    }()
    static func log(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(Date())] \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}

/// 内置终端工具：执行 shell 命令（用 ios_system）
final class ShellExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.exec",
        summary: "执行 shell 命令（终端/命令行/terminal/sh）：完整 Alpine Linux 环境（iSH 引擎），内置 ls/cat/grep/find/tar/curl/python/busybox 全套 + apk 装包 + shell 脚本，cd 记住工作目录。危险命令自动拦截。",
        parameters: [
            "command": "要执行的 shell 命令（必填）",
            "timeout": "超时时间（秒，默认 30，最大 120）",
            "reset_cwd": "可选 Bool：重置工作目录到默认（默认 false）"
        ],
        verified: true
    )
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String, !command.isEmpty else {
            throw MCPError.invalidParams("command required")
        }
        
        // 危险命令检测
        let dangerousPatterns = [
            "^rm\\s+-rf\\s+/$",
            "^rm\\s+-rf\\s+~",
            "^dd\\s+if=",
            "mkfs",
            "^chmod\\s+-R\\s+777\\s+/",
        ]
        for pattern in dangerousPatterns {
            if command.range(of: pattern, options: .regularExpression) != nil {
                return [
                    "error": "危险命令被拦截",
                    "command": command,
                    "hint": "这个命令可能搞坏系统，被安全策略拦截了。"
                ]
            }
        }
        
        // 重置工作目录
        if params["reset_cwd"] as? Bool == true {
            ShellSession.shared.currentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Workspace").path
        }
        
        // v3.0.36: cwd 必须归一化为绝对路径——之前用 pwd 探测的 ~ 前缀显示值覆盖会话目录，
        // 导致 helper chdir("~/...") 失败、所有命令 exit 3
        if !ShellSession.shared.currentDir.hasPrefix("/") {
            if ShellSession.shared.currentDir.hasPrefix("~/") {
                ShellSession.shared.currentDir = NSHomeDirectory() + String(ShellSession.shared.currentDir.dropFirst(1))
            } else {
                ShellSession.shared.currentDir = NSHomeDirectory() + "/Documents/Workspace"
            }
        }
        
        let timeout = min(max((params["timeout"] as? Double) ?? 30, 1), 120)
        let cwd = ShellSession.shared.currentDir
        
        // v3.0.37：默认 iSH 引擎（完整 Alpine Linux，支持任意命令/装包/脚本）。
        // 初始化失败（rootfs 缺失/内核 boot 失败）时回退 ios_system 旧引擎（60 内置命令）。
        var (output, exitCode, timedOut) = ISHEngine.exec(command, timeout: timeout)
        if output.hasPrefix("[ish] 内核初始化失败") || output.hasPrefix("[ish] 内核未就绪") {
            ShellDiag.log("ISH unavailable, fallback ios_system: \(output)")
            _ = IOSSystem.exec("cd '\(cwd)'", timeout: 5)
            let r = IOSSystem.exec(command, timeout: timeout)
            output = r.output
            exitCode = r.exitCode
            timedOut = r.timedOut
        }
        
        // 过滤 ios_system 的 NSLog 调试噪音（格式：2026-09-20 09:36:27.156 TrollMCP2[15683:942233] ...）
        var stdout = ShellExecTool.filterNoise(output)
        if stdout.count > 2000 {
            stdout = String(stdout.prefix(2000)) + "\n... (输出太长，已截断，共 \(stdout.count) 字符)"
        }
        
        // 会话目录：iSH 模式返回 guest 路径，fallback/ios_system 返回 iOS 路径
        var newPwd = ISHEngine.isBooted ? ISHEngine.cwd : ShellSession.shared.currentDir
        
        AuditLog.shared.log("shell.exec", detail: String(command.prefix(100)))
        
        var result: [String: Any] = [
            "command": command,
            "exit_code": exitCode,
            "stdout": stdout,
            "cwd": newPwd,
            "hint": "Alpine Linux 环境：ls/cat/grep/find/tar/curl/python 等全套命令，可 apk add 装包。cd 记住目录。"
        ]
        if timedOut {
            result["timed_out"] = true
            result["hint"] = "命令超过 \(Int(timeout)) 秒未完成，已 SIGKILL 进程组回收。"
        }
        return result
    }
    
    /// 过滤 ios_system 的调试噪音行（NSLog 时间戳行 + 文件描述符统计行）
    static func filterNoise(_ output: String) -> String {
        let noisePattern = "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3} \\S+\\[\\d+:\\d+\\]|Num file descriptors opened = )"
        let lines = output.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            line.range(of: noisePattern, options: .regularExpression) == nil
        }
        return filtered.joined(separator: "\n")
    }
}
