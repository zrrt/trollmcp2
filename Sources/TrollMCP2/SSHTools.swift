import Foundation

// v2.9.68：SSH 远程连接工具
// 通过打包的 ssh 客户端连接 Linux 服务器执行命令
// 配置存在 UserDefaults：ssh_host, ssh_port, ssh_user, ssh_password, ssh_key_path
final class SSHTool: MCPTool {
    let definition = ToolDefinition(
        name: "ssh.exec",
        summary: "通过 SSH 连接远程 Linux 服务器执行命令（需先在设置中配置 SSH 连接信息）。返回命令的 stdout/stderr 和 exit code。",
        parameters: [
            "command": "要在远程服务器执行的 shell 命令（必填）",
            "timeout": "超时秒数（可选，默认 30）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String, !command.isEmpty else {
            throw MCPError.invalidParams("command required")
        }
        let timeout = (params["timeout"] as? Int) ?? 30

        // 读取配置
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "ssh_host") ?? ""
        let port = defaults.integer(forKey: "ssh_port")
        let user = defaults.string(forKey: "ssh_user") ?? ""
        let password = defaults.string(forKey: "ssh_password") ?? ""
        let keyPath = defaults.string(forKey: "ssh_key_path") ?? ""

        guard !host.isEmpty, !user.isEmpty else {
            return [
                "error": "SSH 未配置",
                "hint": "请在设置 → SSH 远程连接中配置 host、port、user、password 或私钥路径",
                "configured": false
            ]
        }

        // 检查 ssh 客户端是否存在
        let sshPath = Bundle.main.path(forResource: "ssh", ofType: nil, inDirectory: "bin") ?? "/usr/bin/ssh"
        guard FileManager.default.fileExists(atPath: sshPath) else {
            return [
                "error": "ssh 客户端未内置",
                "hint": "ssh 二进制未打包到 App 中，将在后续版本添加",
                "ssh_path": sshPath
            ]
        }

        // 构建 ssh 命令
        var args: [String] = []
        args.append("-o")
        args.append("StrictHostKeyChecking=no")
        args.append("-o")
        args.append("UserKnownHostsFile=/dev/null")
        args.append("-o")
        args.append("ConnectTimeout=\(timeout)")
        if port > 0 {
            args.append("-p")
            args.append("\(port)")
        }
        if !keyPath.isEmpty {
            args.append("-i")
            args.append(keyPath)
        }
        args.append("\(user)@\(host)")
        args.append(command)

        // 执行
        let (exitCode, output) = InjectionManager.shared.spawnRoot(sshPath, args: args)

        return [
            "command": command,
            "host": host,
            "user": user,
            "exit_code": exitCode,
            "output": String(output.prefix(5000)),
            "configured": true
        ]
    }
}

// v2.9.68：SSH 文件上传/下载工具
final class SCPTool: MCPTool {
    let definition = ToolDefinition(
        name: "ssh.scp",
        summary: "通过 SCP 在本地和远程 Linux 服务器之间传输文件（需先配置 SSH 连接）。direction=upload 或 download。",
        parameters: [
            "direction": "传输方向：upload（本地→远程）或 download（远程→本地）",
            "local_path": "本地文件路径",
            "remote_path": "远程文件路径"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let direction = (params["direction"] as? String)?.lowercased() ?? "upload"
        guard let localPath = params["local_path"] as? String,
              let remotePath = params["remote_path"] as? String else {
            throw MCPError.invalidParams("local_path and remote_path required")
        }

        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "ssh_host") ?? ""
        let port = defaults.integer(forKey: "ssh_port")
        let user = defaults.string(forKey: "ssh_user") ?? ""

        guard !host.isEmpty, !user.isEmpty else {
            return ["error": "SSH 未配置", "configured": false]
        }

        let scpPath = Bundle.main.path(forResource: "scp", ofType: nil, inDirectory: "bin") ?? "/usr/bin/scp"
        guard FileManager.default.fileExists(atPath: scpPath) else {
            return ["error": "scp 客户端未内置", "scp_path": scpPath]
        }

        var args: [String] = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
        if port > 0 { args.append("-P"); args.append("\(port)") }

        if direction == "upload" {
            args.append(localPath)
            args.append("\(user)@\(host):\(remotePath)")
        } else {
            args.append("\(user)@\(host):\(remotePath)")
            args.append(localPath)
        }

        let (exitCode, output) = InjectionManager.shared.spawnRoot(scpPath, args: args)

        return [
            "direction": direction,
            "local_path": localPath,
            "remote_path": remotePath,
            "exit_code": exitCode,
            "output": String(output.prefix(5000))
        ]
    }
}
