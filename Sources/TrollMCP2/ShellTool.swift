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
        summary: "执行 shell 命令（终端/命令行/terminal/sh）：完整 Alpine Linux 环境（iSH 引擎），内置 ls/cat/grep/find/tar/curl/python/busybox 全套 + apk 装包 + shell 脚本，cd 记住工作目录。危险命令自动拦截。",
        parameters: [
            "command": "Shell command to execute (required)",
            "timeout": "Timeout seconds (default 30, max 120)",
            "reset_cwd": "Optional Bool: reset working dir to default (default false)"
        ],
        verified: true
    , category: "shell")
    
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
        
        // v3.0.41：iSH 为唯一引擎（ios_system 已删除）。初始化失败直接报错，不再回退。
        let (output, exitCode, timedOut) = ISHEngine.exec(command, timeout: timeout)
        
        // 过滤杂散调试噪音
        var stdout = ShellExecTool.filterNoise(output)
        if stdout.count > 2000 {
            stdout = String(stdout.prefix(2000)) + "\n... (输出太长，已截断，共 \(stdout.count) 字符)"
        }
        
        // 会话目录：iSH guest 路径
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
