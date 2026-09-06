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

        // 检查 ssh 客户端是否存在（iOS 系统没有 /usr/bin/ssh，必须包内自带）
        let sshPath = Bundle.main.path(forResource: "ssh", ofType: nil, inDirectory: "bin")
        guard let sshPath = sshPath, FileManager.default.fileExists(atPath: sshPath) else {
            return [
                "error": "ssh 客户端未内置",
                "hint": "iOS 系统没有 /usr/bin/ssh，本版本未打包 ssh 二进制。可先用 ssh.scp 传输文件，或等待后续版本内置 SSH 客户端；私钥认证同样依赖内置 ssh。",
                "ssh_path": Bundle.main.path(forResource: "ssh", ofType: nil, inDirectory: "bin") ?? "(未打包)"
            ]
        }

        // v2.9.87：密码认证需要 sshpass（iOS 无 /usr/bin/sshpass，需包内自带）；
        // 之前读取了 password 但从未传给 ssh → 配置密码的会话必然失败。
        let usePassword = !password.isEmpty && keyPath.isEmpty
        if usePassword {
            let passPath = Bundle.main.path(forResource: "sshpass", ofType: nil, inDirectory: "bin")
            guard let passPath = passPath, FileManager.default.fileExists(atPath: passPath) else {
                return [
                    "error": "密码认证需要 sshpass，但未内置",
                    "hint": "请改用私钥认证（设置中填写 ssh_key_path），或等待后续版本内置 sshpass。",
                    "sshpass_present": false
                ]
            }
            // sshpass -p <password> ssh ...（密码经 argv 传递，不在命令行明文历史）
            var passArgs: [String] = ["-p", password, sshPath]
            passArgs.append(contentsOf: sshArgs(user: user, host: host, port: port, keyPath: nil, command: command, timeout: timeout))
            let (exitCode, output) = InjectionManager.shared.spawnRoot(passPath, args: passArgs)
            return [
                "command": command,
                "host": host,
                "user": user,
                "auth": "password",
                "exit_code": exitCode,
                "output": String(output.prefix(5000)),
                "configured": true
            ]
        }

        // 私钥或无需认证
        let args = sshArgs(user: user, host: host, port: port, keyPath: keyPath, command: command, timeout: timeout)

        // 执行
        let (exitCode, output) = InjectionManager.shared.spawnRoot(sshPath, args: args)

        return [
            "command": command,
            "host": host,
            "user": user,
            "auth": keyPath.isEmpty ? "default" : "key",
            "exit_code": exitCode,
            "output": String(output.prefix(5000)),
            "configured": true
        ]
    }

    private func sshArgs(user: String, host: String, port: Int, keyPath: String?, command: String, timeout: Int) -> [String] {
        var args: [String] = []
        args.append("-o")
        args.append("StrictHostKeyChecking=no")
        args.append("-o")
        args.append("UserKnownHostsFile=/dev/null")
        args.append("-o")
        args.append("ConnectTimeout=\(timeout)")
        args.append("-o")
        args.append("BatchMode=yes")
        if port > 0 {
            args.append("-p")
            args.append("\(port)")
        }
        if let keyPath = keyPath, !keyPath.isEmpty {
            args.append("-i")
            args.append(keyPath)
        }
        args.append("\(user)@\(host)")
        args.append(command)
        return args
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
