import Foundation
import UIKit
import Darwin

/// 终端会话管理（单例，v3.0.93: 已废弃 - iSH 引擎自己管理 cwd，这个类是死代码）
final class ShellSession {
    static let shared = ShellSession()
    private init() {}
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

/// 内置终端工具：执行 shell 命令（iSH 引擎）
final class ShellExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.exec",
        summary: "Run a shell command (terminal/command line/sh): full Alpine Linux (iSH engine), built-in ls/cat/grep/find/tar/curl/python/busybox + apk packages + scripts. cd persists. Dangerous commands auto-blocked. Use for: file operations, scripting, installing packages, downloading files, text processing. Don't use for: UI taps/swipes (use control.* or ui.*), app control (use app.*), injection (use injection.*).",
        parameters: [
            "command": "Shell command to execute (required)",
            "timeout": "Timeout seconds (default 30, max 120)",
            "reset_cwd": "Optional Bool: reset working dir to default (default false)"
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
            ISHEngine.resetCwd()
        }
        
        let timeout = min(max((params["timeout"] as? Double) ?? 30, 1), 120)
        
        // v3.0.41：iSH 为唯一引擎（ios_system 已删除）。初始化失败直接报错，不再回退。
        let (output, exitCode, timedOut) = ISHEngine.exec(command, timeout: timeout)
        
        // 过滤杂散调试噪音
        var stdout = ShellExecTool.filterNoise(output)
        if stdout.count > 2000 {
            stdout = String(stdout.prefix(2000)) + "\n... (输出太长，已截断，共 \(stdout.count) 字符)"
        }
        
        // 会话目录：iSH guest 路径
        var newPwd = ISHEngine.cwd
        
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
    
    /// 过滤杂散调试噪音行
    static func filterNoise(_ output: String) -> String {
        let noisePattern = "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3} \\S+\\[\\d+:\\d+\\]|Num file descriptors opened = )"
        let lines = output.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            line.range(of: noisePattern, options: .regularExpression) == nil
        }
        return filtered.joined(separator: "\n")
    }
}

/// v3.1.1: shell.setup_dev_env — 一键安装基础开发环境
final class ShellSetupDevEnvTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.setup_dev_env",
        summary: "一键安装基础开发环境（python3 + git + vim + curl + 编译工具链）。新用户首次使用终端、或重装后需要开发工具时调用。幂等：已安装的不会重复装。",
        parameters: [
            "skip_python": "可选：跳过 python3 安装（默认 false）",
            "skip_git": "可选：跳过 git 安装（默认 false）"
        ],
        verified: false,
        category: "shell"
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        var packages: [String] = []

        if params["skip_python"] as? Bool != true {
            packages.append("python3 py3-pip")
        }
        if params["skip_git"] as? Bool != true {
            packages.append("git")
        }
        packages.append("vim curl wget build-base clang make")

        let cmd = "apk add --no-cache \(packages.joined(separator: " "))"
        let (output, exitCode, _) = ISHEngine.exec(cmd, timeout: 120)

        var installed: [String] = []
        var failed: [String] = []

        for pkg in ["python3", "git", "vim", "curl", "gcc", "clang"] {
            let (checkOut, checkRc, _) = ISHEngine.exec("which \(pkg)", timeout: 5)
            if checkRc == 0 && !checkOut.isEmpty {
                installed.append(pkg)
            } else {
                failed.append(pkg)
            }
        }

        return [
            "ok": exitCode == 0,
            "command": cmd,
            "exit_code": exitCode,
            "installed": installed,
            "failed": failed,
            "message": exitCode == 0
                ? "Development environment setup complete. Installed: \(installed.joined(separator: ", "))"
                : "Setup may have partially failed. Check output.",
            "hint": "Now you can run python3, git, vim, curl, make, clang directly in shell.exec"
        ]
    }
}
