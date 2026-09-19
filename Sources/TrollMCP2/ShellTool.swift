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
        summary: "执行 shell 命令（终端/命令行/terminal/sh）：解压ipa/deb、查看文件、逆向分析（otool/strings/ls/find/grep）。危险命令自动拦截。cd 记住工作目录。",
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
        
        let timeout = (params["timeout"] as? Double) ?? 30
        let clampedTimeout = min(max(timeout, 5), 120)
        
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
        
        // 先 cd 到当前目录，再执行命令，然后输出新的 PWD
        let fullCommand = "cd '\(cwd)' && \(command); echo '__PWD__:'$PWD"
        
        let (exitCode, output) = InjectionManager.shared.spawn("/bin/sh", args: ["sh", "-c", fullCommand], timeout: clampedTimeout)
        
        // 解析新的 PWD
        var stdout = output
        var newPwd = cwd
        if let range = stdout.range(of: "__PWD__:") {
            let after = stdout[range.upperBound...]
            let lines = after.components(separatedBy: .newlines)
            if let firstLine = lines.first {
                newPwd = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            stdout = String(stdout[..<range.lowerBound])
        }
        ShellSession.shared.currentDir = newPwd
        
        // 输出截断到 2000 字符
        if stdout.count > 2000 {
            stdout = String(stdout.prefix(2000)) + "\n... (输出太长，已截断，共 \(output.count) 字符)"
        }
        
        AuditLog.shared.log("shell.exec", detail: String(command.prefix(100)))
        
        return [
            "command": command,
            "exit_code": exitCode,
            "stdout": stdout,
            "cwd": newPwd,
            "hint": "常用命令：unzip 解包、otool -l 看加密、strings 搜字符串、ls 看文件、find 找文件。cd 会记住目录。"
        ]
    }
}
