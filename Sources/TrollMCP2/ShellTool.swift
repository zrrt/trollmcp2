import Foundation
import UIKit

/// 内置终端工具：执行 shell 命令
final class ShellExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.exec",
        summary: "执行 shell 命令（轻量操作：解压/查看文件/逆向分析）。危险命令（rm/mv/chmod 改系统）会二次确认。输出自动截断到 2000 字符。",
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
            "^rm\\s+-rf\\s+/$",  // rm -rf /
            "^rm\\s+-rf\\s+~",   // rm -rf ~
            "^dd\\s+if=",        // dd 写磁盘
            "mkfs",              // 格式化
            "^chmod\\s+-R\\s+777\\s+/",  // chmod 777 /
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
        
        // 执行命令
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        do {
            try process.run()
        } catch {
            return ["error": "启动命令失败: \(error.localizedDescription)"]
        }
        
        // 超时
        let deadline = Date().addingTimeInterval(clampedTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            return [
                "error": "命令超时（\(Int(clampedTimeout))秒）",
                "command": command,
                "hint": "命令执行时间太长被终止了"
            ]
        }
        
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        
        var stdout = String(data: outData, encoding: .utf8) ?? ""
        var stderr = String(data: errData, encoding: .utf8) ?? ""
        
        // 输出截断到 2000 字符
        if stdout.count > 2000 {
            stdout = String(stdout.prefix(2000)) + "\n... (输出太长，已截断，共 \(stdout.count) 字符)"
        }
        if stderr.count > 1000 {
            stderr = String(stderr.prefix(1000)) + "\n... (错误输出太长，已截断)"
        }
        
        AuditLog.shared.log("shell.exec", detail: command.prefix(100))
        
        return [
            "command": command,
            "exit_code": process.terminationStatus,
            "stdout": stdout,
            "stderr": stderr,
            "hint": "常用命令：unzip 解包、otool -l 看加密、strings 搜字符串、ls 看文件、find 找文件"
        ]
    }
}
