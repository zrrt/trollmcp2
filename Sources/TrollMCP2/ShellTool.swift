import Foundation
import UIKit

/// 内置终端工具：执行 shell 命令
final class ShellExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.exec",
        summary: "执行 shell 命令（轻量操作：解压/查看文件/逆向分析）。危险命令会被拦截。输出自动截断到 2000 字符。",
        parameters: [
            "command": "要执行的 shell 命令（必填）",
            "timeout": "超时时间（秒，默认 30，最大 120）"
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
        
        // 用项目已有的 spawn 函数执行
        let (exitCode, output) = InjectionManager.shared.spawn("/bin/bash", args: ["bash", "-c", command], timeout: clampedTimeout)
        
        // 输出截断到 2000 字符
        var stdout = output
        var stderr = ""
        if stdout.count > 2000 {
            stdout = String(stdout.prefix(2000)) + "\n... (输出太长，已截断，共 \(output.count) 字符)"
        }
        
        AuditLog.shared.log("shell.exec", detail: String(command.prefix(100)))
        
        return [
            "command": command,
            "exit_code": exitCode,
            "stdout": stdout,
            "stderr": stderr,
            "hint": "常用命令：unzip 解包、otool -l 看加密、strings 搜字符串、ls 看文件、find 找文件"
        ]
    }
}
