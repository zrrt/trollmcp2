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
    
    /// 执行命令。返回 (输出, 退出码, 是否超时)
    static func exec(_ command: String, timeout: TimeInterval = 30) -> (output: String, exitCode: Int32, timedOut: Bool) {
        load()
        guard let handle = handle else { return ("[shell] ios_system 未加载", -1, false) }
        guard let funcPtr = dlsym(handle, "ios_system") else { return ("[shell] 找不到 ios_system 符号", -1, false) }
        typealias ios_system_func = @convention(c) (UnsafePointer<CChar>) -> Int32
        let execFn = unsafeBitCast(funcPtr, to: ios_system_func.self)
        
        // C 风格 pipe：dup2 后立刻关自己的写端引用，命令结束后读端才能收到 EOF
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return ("[shell] pipe 创建失败", -1, false) }
        let readFD = fds[0]
        let writeFD = fds[1]
        
        let oldStdout = dup(STDOUT_FILENO)
        let oldStderr = dup(STDERR_FILENO)
        dup2(writeFD, STDOUT_FILENO)
        dup2(writeFD, STDERR_FILENO)
        close(writeFD)
        
        let outputBuf = NSMutableString()
        var exitCode: Int32 = -1
        let done = DispatchSemaphore(value: 0)
        
        DispatchQueue.global(qos: .userInitiated).async {
            var code: Int32 = -1
            _ = command.withCString { cCmd in
                code = execFn(cCmd)
            }
            fflush(stdout)
            fflush(stderr)
            dup2(oldStdout, STDOUT_FILENO)
            dup2(oldStderr, STDERR_FILENO)
            close(oldStdout)
            close(oldStderr)
            // 读剩余输出直到 EOF（写端已全部关闭，read 返回 0 即结束）
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(readFD, &buf, buf.count)
                if n <= 0 { break }
                outputBuf.append(String(decoding: buf[0..<n], as: UTF8.self))
            }
            close(readFD)
            exitCode = code
            done.signal()
        }
        
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // 尝试终止卡住的命令（ios_kill 结束当前正在运行的命令）
            if let killPtr = dlsym(handle, "ios_kill") {
                typealias kill_func = @convention(c) () -> Int32
                let killFn = unsafeBitCast(killPtr, to: kill_func.self)
                killFn()
            }
            // 最多再等 2 秒让后台线程清理；若命令真不退出，调用方先返回，避免 MCP 调用卡死
            _ = done.wait(timeout: .now() + 2)
        }
        
        return (outputBuf as String, exitCode, timedOut)
    }
}

/// 内置终端工具：执行 shell 命令（用 ios_system）
final class ShellExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.exec",
        summary: "执行 shell 命令（终端/命令行/terminal/sh）：内置 ls/cat/grep/find/unzip/tar/curl 等100+命令，解压ipa/deb、逆向分析、文件操作。危险命令自动拦截。cd 记住工作目录。",
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
        
        let timeout = min(max((params["timeout"] as? Double) ?? 30, 1), 120)
        let cwd = ShellSession.shared.currentDir
        
        // 先切到会话工作目录，再执行命令（分开两次调用，不依赖 shell 对 && 的支持）
        _ = IOSSystem.exec("cd '\(cwd)'", timeout: 5)
        let (output, exitCode, timedOut) = IOSSystem.exec(command, timeout: timeout)
        
        // 过滤 ios_system 的 NSLog 调试噪音（格式：2026-09-20 09:36:27.156 TrollMCP2[15683:942233] ...）
        var stdout = ShellExecTool.filterNoise(output)
        if stdout.count > 2000 {
            stdout = String(stdout.prefix(2000)) + "\n... (输出太长，已截断，共 \(stdout.count) 字符)"
        }
        
        // 获取当前工作目录
        var newPwd = cwd
        let pwdResult = IOSSystem.exec("pwd", timeout: 5)
        let pwd = ShellExecTool.filterNoise(pwdResult.output).trimmingCharacters(in: .whitespacesAndNewlines)
        if !pwd.isEmpty { newPwd = pwd }
        ShellSession.shared.currentDir = newPwd
        
        AuditLog.shared.log("shell.exec", detail: String(command.prefix(100)))
        
        var result: [String: Any] = [
            "command": command,
            "exit_code": exitCode,
            "stdout": stdout,
            "cwd": newPwd,
            "hint": "内置命令：ls/cat/grep/find/tar/awk/cd/echo 等 + $APPDIR/bin 外部工具（ldid/optool 等）。cd 记住目录。"
        ]
        if timedOut {
            result["timed_out"] = true
            result["hint"] = "命令超过 \(Int(timeout)) 秒未完成，已尝试用 ios_kill 终止。"
        }
        return result
    }
    
    /// 过滤 ios_system 的 NSLog 调试噪音行
    static func filterNoise(_ output: String) -> String {
        let noisePattern = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3} \\S+\\[\\d+:\\d+\\]"
        let lines = output.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            line.range(of: noisePattern, options: .regularExpression) == nil
        }
        return filtered.joined(separator: "\n")
    }
}
