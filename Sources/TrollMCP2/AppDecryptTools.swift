import Foundation

// v2.9.68：应用解密（砸壳）工具
// 通过 task_for_pid 读取目标 App 进程内存，替换加密段为解密后的数据
// 支持两种模式：
// 1. clutch 模式：调用打包的 clutch 二进制（推荐，兼容性好）
// 2. 内存 dump 模式：直接读取进程内存解密（简化版）
final class AppDecryptTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.decrypt",
        summary: "对已安装的 App 进行砸壳解密（去除 App Store 加密）。需要目标 App 正在运行。输出解密后的 IPA 到工作区。",
        parameters: [
            "bundle_id": "目标 App 的 Bundle ID（必填，可用 injection.list 搜索）",
            "mode": "解密模式：clutch（调用打包的 clutch，默认）或 memory（内存 dump）",
            "output_name": "输出文件名（可选，默认用 App 名称）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let mode = (params["mode"] as? String)?.lowercased() ?? "clutch"
        let outputName = params["output_name"] as? String

        // 查找目标 App
        let apps = AppCatalog.list()
        guard let target = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["error": "未找到 App: \(bundleId)", "hint": "用 injection.list 搜索目标 App 的 bundle_id"]
        }

        // 检查目标是否正在运行
        let pid = findProcess(by: bundleId)
        guard pid > 0 else {
            return [
                "error": "目标 App 未运行",
                "bundle_id": bundleId,
                "app_name": target.name,
                "hint": "请先打开目标 App，保持在前台或后台运行，再执行砸壳"
            ]
        }

        AuditLog.shared.log("app.decrypt", detail: "\(bundleId) pid=\(pid) mode=\(mode)")

        if mode == "clutch" {
            return try decryptWithClutch(bundleId: bundleId, pid: pid, appName: target.name, outputName: outputName)
        } else {
            return try decryptWithMemoryDump(bundleId: bundleId, pid: pid, appName: target.name, outputName: outputName)
        }
    }

    // MARK: - clutch 模式

    private func decryptWithClutch(bundleId: String, pid: Int32, appName: String, outputName: String?) throws -> [String: Any] {
        let clutchPath = Bundle.main.path(forResource: "clutch", ofType: nil, inDirectory: "bin")
        guard let clutchPath = clutchPath, FileManager.default.fileExists(atPath: clutchPath) else {
            return [
                "error": "clutch 未内置",
                "hint": "clutch 二进制未打包到 App 中，将在后续版本添加；当前可用 memory 模式",
                "clutch_path": clutchPath ?? "not found"
            ]
        }

        let workspace = NSHomeDirectory().appending("/Documents/Workspace")
        let outputDir = workspace.appending("/decrypted")
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let (exitCode, output) = InjectionManager.shared.spawnRoot(clutchPath, args: ["-d", bundleId, "--output", outputDir])

        // 查找输出文件
        let files = (try? FileManager.default.contentsOfDirectory(atPath: outputDir)) ?? []
        let ipaFiles = files.filter { $0.hasSuffix(".ipa") }

        return [
            "mode": "clutch",
            "bundle_id": bundleId,
            "app_name": appName,
            "pid": pid,
            "exit_code": exitCode,
            "output": String(output.prefix(3000)),
            "output_dir": outputDir,
            "decrypted_files": ipaFiles,
            "success": exitCode == 0 && !ipaFiles.isEmpty
        ]
    }

    // MARK: - 内存 dump 模式（简化版）

    private func decryptWithMemoryDump(bundleId: String, pid: Int32, appName: String, outputName: String?) throws -> [String: Any] {
        // 通过 task_for_pid 获取进程端口
        var task: UInt32 = 0
        let kr = DeviceProbe.shared.tm_task_for_pid(DeviceProbe.shared.tm_mach_task_self(), pid, &task)
        guard kr == KERN_SUCCESS, task != 0 else {
            return [
                "error": "task_for_pid 失败",
                "kern_return": Int(kr),
                "hint": "需要 task_for_pid-allow entitlement（TrollStore 开启编辑 Entitlements 后卸载重装）"
            ]
        }

        // 读取 MachO 头，找到加密段
        // 简化版：复制 App Bundle，用进程内存替换 __TEXT 段
        let apps = AppCatalog.list()
        guard let target = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["error": "未找到 App 路径"]
        }

        let bundlePath = target.path
        let workspace = NSHomeDirectory().appending("/Documents/Workspace/decrypted")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)

        let safeName = (outputName ?? appName).replacingOccurrences(of: " ", with: "_")
        let outputPath = workspace.appending("/\(safeName)-decrypted.ipa")

        // 复制原始 Bundle
        let tempDir = workspace.appending("/\(safeName)_temp")
        try? FileManager.default.removeItem(atPath: tempDir)
        do {
            try FileManager.default.copyItem(atPath: bundlePath, toPath: tempDir)
        } catch {
            return ["error": "复制 App Bundle 失败: \(error.localizedDescription)", "bundle_path": bundlePath]
        }

        // 找到主二进制
        let plistPath = tempDir.appending("/Info.plist")
        let plist = NSDictionary(contentsOfFile: plistPath)
        let executable = (plist?["CFBundleExecutable"] as? String) ?? appName
        let binaryPath = tempDir.appending("/\(executable)")

        // 用 ldid 检查是否有加密段
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        if !ldidPath.isEmpty {
            _ = InjectionManager.shared.spawnRoot(ldidPath, args: ["-e", binaryPath])
        }

        // 内存 dump 的核心逻辑：
        // 1. 读取 MachO 头，找到 LC_ENCRYPTION_INFO_64
        // 2. 通过 vm_read_overwrite 读取进程内存中对应地址的数据
        // 3. 替换文件中的加密段
        // 4. 清除 cryptid 标志
        // 这个实现比较复杂，这里先返回框架状态
        DeviceProbe.shared.tm_mach_port_deallocate(DeviceProbe.shared.tm_mach_task_self(), task)

        return [
            "mode": "memory",
            "bundle_id": bundleId,
            "app_name": appName,
            "pid": pid,
            "task_port": task,
            "bundle_path": bundlePath,
            "temp_dir": tempDir,
            "binary_path": binaryPath,
            "output_path": outputPath,
            "status": "框架已就绪，内存 dump 核心逻辑待完善",
            "hint": "建议使用 clutch 模式（需打包 clutch 二进制），兼容性更好",
            "success": false
        ]
    }

    // MARK: - 辅助方法

    private func findProcess(by bundleId: String) -> Int32 {
        // 通过 sysctl 获取进程列表，匹配 bundleId
        // 简化：用 ps 命令查找
        let (_, output) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-ax"])
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains(bundleId) || line.contains(bundleId.replacingOccurrences(of: ".", with: "")) {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                if let pidStr = parts.first, let pid = Int32(pidStr) {
                    return pid
                }
            }
        }
        return 0
    }
}

// v2.9.68：查看 App 加密状态工具
final class AppEncryptInfoTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.encrypt_info",
        summary: "查看指定 App 的加密状态（是否砸壳、加密段信息、签名信息）。",
        parameters: [
            "bundle_id": "目标 App 的 Bundle ID（必填）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }

        let apps = AppCatalog.list()
        guard let target = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["error": "未找到 App: \(bundleId)"]
        }

        let plistPath = target.path.appending("/Info.plist")
        let plist = NSDictionary(contentsOfFile: plistPath)
        let executable = (plist?["CFBundleExecutable"] as? String) ?? target.name
        let binaryPath = target.path.appending("/\(executable)")

        // 用 otool 或 ldid 检查加密段
        let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
        var cryptInfo = "未知"
        if FileManager.default.fileExists(atPath: otoolPath) {
            let (_, output) = InjectionManager.shared.spawnRoot(otoolPath, args: ["-l", binaryPath])
            if output.contains("LC_ENCRYPTION_INFO") {
                cryptInfo = "已加密（App Store 下载）"
            } else {
                cryptInfo = "未加密（已砸壳或侧载）"
            }
        }

        // 检查签名
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        var signInfo = "未知"
        if !ldidPath.isEmpty {
            let (_, output) = InjectionManager.shared.spawnRoot(ldidPath, args: ["-e", binaryPath])
            signInfo = output.isEmpty ? "无签名信息" : "已签名"
        }

        return [
            "bundle_id": bundleId,
            "app_name": target.name,
            "bundle_path": target.path,
            "binary_path": binaryPath,
            "encryption_status": cryptInfo,
            "signature_status": signInfo,
            "version": plist?["CFBundleShortVersionString"] as? String ?? "未知",
            "build": plist?["CFBundleVersion"] as? String ?? "未知"
        ]
    }
}
