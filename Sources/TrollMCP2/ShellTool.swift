import Foundation
import UIKit

/// 终端会话管理（单例，记住当前工作目录）
final class ShellSession {
    static let shared = ShellSession()
    private init() {}
    
    var currentDir: String = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Workspace").path
}

/// 内置终端工具：执行 shell 命令
final class ShellExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.exec",
        summary: "执行 shell 命令（终端/命令行/terminal/sh）：文件操作、解压ipa/deb、逆向分析。危险命令自动拦截。cd 记住工作目录。",
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
                    "hint": "这个命令可能搞坏系统，被安全策略拦截了。如果确实要执行，请手动在 NewTerm3 里跑。"
                ]
            }
        }
        
        // 重置工作目录
        if params["reset_cwd"] as? Bool == true {
            ShellSession.shared.currentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Workspace").path
        }
        
        let cwd = ShellSession.shared.currentDir
        
        // 先 cd 到当前目录，再执行命令
        let fullCommand = "cd '\(cwd)' && \(command)"
        
        // 用系统 /bin/sh 执行
        let (exitCode, output) = InjectionManager.shared.spawn("/bin/sh", args: ["sh", "-c", fullCommand], timeout: 30)
        
        // 输出截断到 2000 字符
        var stdout = output
        if stdout.count > 2000 {
            stdout = String(stdout.prefix(2000)) + "\n... (输出太长，已截断，共 \(stdout.count) 字符)"
        }
        
        // 获取当前工作目录
        var newPwd = cwd
        let (_, pwdOut) = InjectionManager.shared.spawn("/bin/sh", args: ["sh", "-c", "cd '\(cwd)' && pwd"], timeout: 5)
        if !pwdOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newPwd = pwdOut.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        ShellSession.shared.currentDir = newPwd
        
        AuditLog.shared.log("shell.exec", detail: String(command.prefix(100)))
        
        return [
            "command": command,
            "exit_code": exitCode,
            "stdout": stdout,
            "cwd": newPwd,
            "hint": "常用命令：ls/cat/grep/find/unzip/tar/curl 等。cd 记住工作目录。"
        ]
    }
}

