import Foundation

// v2.9.128：应用解密（砸壳）工具 —— 引擎实现在 DecryptEngine.swift
// 原理（对齐 TrollDecrypt 全量算法）：
//   启动目标 App → task_for_pid → task_info(TASK_DYLD_INFO) 遍历 dyld 镜像
//   → 找主二进制加载地址 → 读 LC_ENCRYPTION_INFO_64 → mach_vm_read_overwrite
//   从进程内存读解密段 → 重建镜像并清 cryptid → 处理 Frameworks → 打包 IPA
// 失败四分类（CLI 协议）：env（权限/环境）/ target（App/进程/启动）/ param / tool（解析/打包）

final class AppDecryptTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.decrypt",
        summary: "对已安装的 App 进行砸壳解密（去除 App Store 加密）。需要目标 App 正在运行（未运行会自动启动）。输出解密后的 IPA 到工作区 decrypted/ 目录。",
        parameters: [
            "bundle_id": "目标 App 的 Bundle ID（必填，可用 injection.list 搜索）",
            "output_name": "输出文件名前缀（可选，默认用 App 名称）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let outputName = params["output_name"] as? String

        AuditLog.shared.log("app.decrypt", detail: bundleId)
        let r = DecryptEngine.decryptApp(bundleId: bundleId, outputName: outputName)

        guard r.ok else {
            return [
                "ok": false,
                "error": [
                    "code": r.errorCode,
                    "reason": r.errorReason,
                    "next_step": r.nextStep
                ],
                "bundle_id": bundleId,
                "pid": r.pid,
                "launch_errors": r.launchErrors
            ]
        }

        return [
            "ok": true,
            "message": "砸壳完成：\(r.outputName)",
            "data": [
                "bundle_id": bundleId,
                "pid": r.pid,
                "output_path": r.outputPath,
                "output_name": r.outputName,
                "decrypted_binaries": r.decryptedBinaries,
                "crypt_info": r.cryptInfo,
                "launch_errors": r.launchErrors,
                "diag": r.diag
            ]
        ]
    }
}

// v2.9.128：查看 App 加密状态工具（增强）
// 目标 App 正在运行时：直接进进程读 LC_ENCRYPTION_INFO_64，返回精确 cryptid/cryptoff/cryptsize
// 未运行时：otool -l 解析，且区分"解析失败（加密/特殊 mach-o）"vs"确实未加密"
final class AppEncryptInfoTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.encrypt_info",
        summary: "查看指定 App 的加密状态（cryptid/cryptoff/cryptsize、签名）。App 正在运行时读进程内存精确解析，未运行时用 otool 且区分解析失败与未加密。",
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
            return ["ok": false, "error": ["code": "target", "reason": "未找到 App: \(bundleId)",
                    "next_step": "用 injection.list 搜索目标 App 的 bundle_id"]]
        }

        let plistPath = target.path.appending("/Info.plist")
        let plist = NSDictionary(contentsOfFile: plistPath)
        let executable = (plist?["CFBundleExecutable"] as? String) ?? target.name
        let binaryPath = target.path.appending("/\(executable)")

        // 方式 A：进程内精确解析（App 正在运行）
        var pid = findPidFor(by: bundleId)
        var processInfo: [String: Any] = [:]
        if pid > 0 {
            var task: UInt32 = 0
            let kr = DeviceProbe.shared.tm_task_for_pid(DeviceProbe.shared.tm_mach_task_self(), pid, &task)
            if kr == 0, task != 0 {
                defer { DeviceProbe.shared.tm_mach_port_deallocate(DeviceProbe.shared.tm_mach_task_self(), task) }
                if let loadAddr = DecryptEngine.findImageLoadAddress(task: task, pid: pid, binaryPath: binaryPath) {
                    if let enc = DecryptEngine.readEncryptionInfo(task: task, loadAddress: loadAddr) {
                        processInfo = [
                            "pid": pid,
                            "load_address": String(format: "0x%llx", loadAddr),
                            "cryptid": enc.cryptid,
                            "cryptoff": enc.cryptoff,
                            "cryptsize": enc.cryptsize,
                            "encrypted": enc.cryptid != 0
                        ]
                    } else {
                        processInfo = ["pid": pid, "parse_error": "读 Mach-O load commands 失败"]
                    }
                } else {
                    processInfo = ["pid": pid, "parse_error": "dyld 镜像表未找到主二进制"]
                }
            } else {
                processInfo = ["pid": pid, "task_for_pid_error": "kern_return=\(Int(kr))"]
            }
        }

        // 方式 B：otool 静态解析（未运行或需要二次确认）
        let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
        var staticInfo: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: otoolPath) {
            // v2.9.126：只取 stdout——otool 警告/错误在 stderr，不混入解析结果
            let out = InjectionManager.shared.spawnRootDetailed(otoolPath, args: ["-l", binaryPath], timeout: 60).stdout
            if out.contains("LC_ENCRYPTION_INFO") {
                // 提取 cryptid/cryptoff/cryptsize 具体值
                var cryptid: Int32 = -1
                var cryptoff: Int32 = -1
                var cryptsize: Int32 = -1
                let lines = out.components(separatedBy: .newlines)
                for i in 0..<lines.count {
                    let line = lines[i]
                    if line.contains("cryptid") {
                        cryptid = extractInt(line, "cryptid")
                    } else if line.contains("cryptoff") {
                        cryptoff = extractInt(line, "cryptoff")
                    } else if line.contains("cryptsize") {
                        cryptsize = extractInt(line, "cryptsize")
                    }
                }
                staticInfo = ["has_encryption_cmd": true, "cryptid": cryptid,
                              "cryptoff": cryptoff, "cryptsize": cryptsize,
                              "encrypted": cryptid == 1]
            } else if out.contains("LC_ENCRYPTION") {
                staticInfo = ["has_encryption_cmd": true, "parse_error": "含加密命令但 otool 输出格式异常"]
            } else {
                staticInfo = ["has_encryption_cmd": false, "cryptid": 0, "encrypted": false]
            }
        } else {
            staticInfo = ["otool": "not_found"]
        }

        // 签名检查
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        var signInfo = "未知"
        if !ldidPath.isEmpty {
            // v2.9.126：只取 stdout——ldid 的 plist 解析错误在 stderr，不再误判"无签名"
            let output = InjectionManager.shared.spawnRootDetailed(ldidPath, args: ["-e", binaryPath], timeout: 30).stdout
            signInfo = output.isEmpty ? "无签名信息" : "已签名"
        }

        return [
            "ok": true,
            "data": [
                "bundle_id": bundleId,
                "app_name": target.name,
                "bundle_path": target.path,
                "binary_path": binaryPath,
                "version": plist?["CFBundleShortVersionString"] as? String ?? "未知",
                "build": plist?["CFBundleVersion"] as? String ?? "未知",
                "signature_status": signInfo,
                "process_info": processInfo,
                "static_info": staticInfo,
                "conclusion": conclusion(processInfo: processInfo, staticInfo: staticInfo)
            ]
        ]
    }

    private func conclusion(processInfo: [String: Any], staticInfo: [String: Any]) -> String {
        if let pid = processInfo["pid"] as? Int32, pid > 0 {
            if let enc = processInfo["encrypted"] as? Bool {
                return enc ? "运行中进程检测到加密（cryptid=1），可用 app.decrypt 砸壳" : "运行中进程确认未加密（cryptid=0），无需砸壳"
            }
            if let _ = processInfo["parse_error"] {
                return "进程解析失败（可能是加密+反调试拦截），静态结果见 static_info"
            }
        }
        if let enc = staticInfo["encrypted"] as? Bool {
            return enc ? "静态检测为已加密（cryptid=1），请启动目标 App 后用 app.decrypt 砸壳" : "静态检测为未加密（已砸壳或侧载）"
        }
        if let _ = staticInfo["parse_error"] {
            return "静态解析异常（可能是加密二进制或特殊 Mach-O），启动 App 后用 app.decrypt 尝试进程内砸壳"
        }
        return "otool 不可用，无法静态判断；启动 App 后用 app.encrypt_info 复查（进程内解析）"
    }

    private func extractInt(_ line: String, _ key: String) -> Int32 {
        let parts = line.components(separatedBy: key)
        guard parts.count > 1 else { return -1 }
        let rest = parts[1]
        // 跳过非数字，取第一个数字串
        var digits = ""
        for ch in rest {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Int32(digits) ?? -1
    }

    /// v2.9.184：改 libproc 枚举（TrollStore 无 shell 环境 ps 不可用，实测 running 恒 false）
    private func findPidFor(by bundleId: String) -> Int32 {
        if let entry = AppCatalog.find(bundleId) {
            let exePath = entry.path + "/" + entry.execName
            let pid = findPidByExecutable(bundlePath: exePath)
            if pid > 0 { return pid }
            let pid2 = findPidByExecutable(bundlePath: entry.path)
            if pid2 > 0 { return pid2 }
        }
        let output = InjectionManager.shared.spawnRootDetailed("/bin/ps", args: ["-ax"], timeout: 30).stdout
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
