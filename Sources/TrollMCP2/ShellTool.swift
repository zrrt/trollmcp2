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
        
        // v3.1.32: iOS 原生命令拦截——直接用 iOS FileManager 执行，不经过 Alpine
        // 这样就能访问整个 iOS 文件系统了！
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. ls 命令——iOS 原生实现
        if trimmed.hasPrefix("ls ") || trimmed == "ls" {
            let result = ShellExecTool.runIOSls(trimmed)
            AuditLog.shared.log("shell.exec (ios ls)", detail: String(trimmed.prefix(100)))
            return result
        }
        
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
    
    /// v3.1.32: iOS 原生 ls 命令——直接访问 iOS 文件系统
    private static func runIOSls(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        var showAll = false
        var showLong = false
        var path = "."
        
        // 解析选项
        for part in parts.dropFirst() {
            if part.hasPrefix("-") {
                showAll = part.contains("a")
                showLong = part.contains("l")
            } else {
                path = part
            }
        }
        
        // 解析路径
        var resolvedPath = (path as NSString).expandingTildeInPath
        if resolvedPath == "." || resolvedPath == "./" {
            resolvedPath = NSHomeDirectory() + "/Documents"
        }
        
        // 检查目录是否存在
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "ls: cannot access '\(path)': No such file or directory",
                "cwd": NSHomeDirectory() + "/Documents",
                "ios_native": true,
                "hint": "iOS 原生 ls：直接访问 iOS 文件系统"
            ]
        }
        
        // 列出目录内容
        do {
            let items = try fm.contentsOfDirectory(atPath: resolvedPath)
            let sorted = items.sorted()
            
            if showLong {
                // 长格式输出（简化版）
                var lines: [String] = []
                lines.append("total \(items.count)")
                for item in sorted {
                    if !showAll && item.hasPrefix(".") { continue }
                    let fullPath = resolvedPath + "/" + item
                    var itemIsDir: ObjCBool = false
                    fm.fileExists(atPath: fullPath, isDirectory: &itemIsDir)
                    let type = itemIsDir.boolValue ? "d" : "-"
                    // 简化：只显示类型和名字
                    lines.append("\(type)rwxr-xr-x  1  mobile  mobile  \(String(format: "%8d", 4096))  \(item)")
                }
                return [
                    "command": command,
                    "exit_code": 0,
                    "stdout": lines.joined(separator: "\n"),
                    "cwd": resolvedPath,
                    "ios_native": true,
                    "hint": "iOS 原生 ls：直接访问 iOS 文件系统"
                ]
            } else {
                // 短格式输出
                let visible = showAll ? sorted : sorted.filter { !$0.hasPrefix(".") }
                return [
                    "command": command,
                    "exit_code": 0,
                    "stdout": visible.joined(separator: "  "),
                    "cwd": resolvedPath,
                    "ios_native": true,
                    "hint": "iOS 原生 ls：直接访问 iOS 文件系统"
                ]
            }
        } catch {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "ls: cannot access '\(path)': \(error.localizedDescription)",
                "cwd": resolvedPath,
                "ios_native": true,
                "hint": "iOS 原生 ls"
            ]
        }
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
