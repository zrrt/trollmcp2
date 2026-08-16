import Foundation
import UIKit

/// 注入管理器：使用内置 ldid / optool / insert_dylib / ct_bypass 二进制，通过 posix_spawn
/// 真实地把 TrollMCPAgent.dylib 注入到目标 App 主可执行文件（TrollStore 无越狱注入）。
final class InjectionManager {
    static let shared = InjectionManager()

    private var binDir: URL {
        Bundle.main.bundleURL.appendingPathComponent("bin")
    }

    func binaryPath(_ name: String) -> String? {
        let p = binDir.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    func availableBinaries() -> [String] {
        let names = ["ldid", "optool", "insert_dylib", "ct_bypass", "install_name_tool",
                     "chown", "cp", "cp-15", "mkdir", "mv", "mv-15", "rm"]
        return names.filter { binaryPath($0) != nil }
    }

    // MARK: - posix_spawn 执行包内二进制

    /// 执行包内二进制，捕获 stdout/stderr，返回 (exitCode, combinedOutput)
    @discardableResult
    func runBundled(_ name: String, args: [String]) -> (Int32, String) {
        guard let bin = binaryPath(name) else { return (-1, "binary not bundled: \(name)") }
        let result = spawn(bin, args: [name] + args)
        // 权限/签名问题：ldid 重签后重试一次
        if result.0 != 0, name != "ldid", let ldid = binaryPath("ldid") {
            _ = spawn(ldid, args: ["-S", bin])
            let retry = spawn(bin, args: [name] + args)
            if retry.0 == 0 { return retry }
        }
        return result
    }

    func spawn(_ path: String, args: [String]) -> (Int32, String) {
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var pid: pid_t = 0
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        pipe(&outPipe)
        pipe(&errPipe)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])

        var env: [UnsafeMutablePointer<CChar>?] = [
            strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"),
            strdup("HOME=/var/mobile"),
            nil
        ]
        defer { for p in env where p != nil { free(p) } }

        let status = posix_spawn(&pid, path, &fileActions, nil, &argv, &env)
        posix_spawn_file_actions_destroy(&fileActions)
        close(outPipe[1]); close(errPipe[1])

        var out = Data()
        if status == 0 {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(outPipe[0], &buf, buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            var buf2 = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(errPipe[0], &buf2, buf2.count)
                if n <= 0 { break }
                out.append(buf2, count: n)
            }
            var st: Int32 = 0
            waitpid(pid, &st, 0)
            close(outPipe[0]); close(errPipe[0])
            let code = Int32((UInt32(st) >> 8) & 0xff)  // WEXITSTATUS
            return (code, String(data: out, encoding: .utf8) ?? "")
        }
        close(outPipe[0]); close(errPipe[0])
        return (status, "posix_spawn failed (\(status))")
    }

    // MARK: - 路径解析

    func executablePath(_ app: AppCatalog.AppEntry) -> String {
        let plist = (app.path as NSString).appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOfFile: plist),
           let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty {
            return (app.path as NSString).appendingPathComponent(exe)
        }
        let fallback = app.bundleId.split(separator: ".").last.map(String.init) ?? app.bundleId
        return (app.path as NSString).appendingPathComponent(fallback)
    }

    /// 通过扫描二进制内是否含 "TrollMCPAgent" 字符串判断注入状态（LC_LOAD_DYLIB 名字会被写入）
    func isInjected(_ mainBinary: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: mainBinary)) else { return false }
        return data.range(of: "TrollMCPAgent".data(using: .utf8)!) != nil
    }

    // MARK: - 公共 API

    /// 注入 dylib 到指定 App：拷贝 agent → insert_dylib --inplace → ldid -S 重签
    func enable(bundleId: String, dylibName: String = "@executable_path/TrollMCPAgent.dylib") throws -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        guard binaryPath("insert_dylib") != nil,
              binaryPath("ldid") != nil else {
            throw MCPError.failed("insert_dylib / ldid 未内置")
        }
        let mainBinary = executablePath(app)
        guard FileManager.default.fileExists(atPath: mainBinary) else {
            throw MCPError.failed("主二进制不存在: \(mainBinary)")
        }
        let agentSrc = Bundle.main.bundleURL.appendingPathComponent("TrollMCPAgent.dylib").path
        guard FileManager.default.fileExists(atPath: agentSrc) else {
            throw MCPError.failed("TrollMCPAgent.dylib 未内置")
        }
        let agentDst = (app.path as NSString).appendingPathComponent("TrollMCPAgent.dylib")

        // 1. 拷贝 agent dylib 进目标 App（@executable_path 可解析）
        if !FileManager.default.fileExists(atPath: agentDst) {
            try FileManager.default.copyItem(atPath: agentSrc, toPath: agentDst)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentDst)

        // 2. 备份原始主二进制
        let backup = mainBinary + ".bak_macho"
        if !FileManager.default.fileExists(atPath: backup) {
            try FileManager.default.copyItem(atPath: mainBinary, toPath: backup)
        }

        // 3. insert_dylib --inplace
        let (c1, o1) = runBundled("insert_dylib", args: ["--inplace", dylibName, mainBinary])
        guard c1 == 0 else {
            throw MCPError.failed("insert_dylib 失败(\(c1)): \(o1)")
        }

        // 4. ldid -S 重签（无 entitlements）
        let (c2, o2) = runBundled("ldid", args: ["-S", mainBinary])

        let injected = isInjected(mainBinary)
        AuditLog.shared.log("injection.enable", detail: "\(bundleId) → \(mainBinary) injected=\(injected)")
        return [
            "action": "inject",
            "app": app.name,
            "bundleId": bundleId,
            "mainBinary": mainBinary,
            "dylib": dylibName,
            "backup": backup,
            "insert_dylib_exit": Int(c1),
            "ldid_exit": Int(c2),
            "insert_output": o1,
            "ldid_output": o2,
            "injected": injected,
            "status": injected ? "injected" : "injection_failed"
        ]
    }

    /// 还原注入（用备份覆盖主二进制），保留 dylib 文件
    func disable(bundleId: String) throws -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        let mainBinary = executablePath(app)
        let backup = mainBinary + ".bak_macho"
        guard FileManager.default.fileExists(atPath: backup) else {
            throw MCPError.failed("未找到注入备份，可能从未注入或无法还原")
        }
        try FileManager.default.removeItem(atPath: mainBinary)
        try FileManager.default.copyItem(atPath: backup, toPath: mainBinary)
        let (c, o) = runBundled("ldid", args: ["-S", mainBinary])
        let injected = isInjected(mainBinary)
        AuditLog.shared.log("injection.disable", detail: bundleId)
        return [
            "action": "remove",
            "bundleId": bundleId,
            "restored_from_backup": true,
            "ldid_exit": Int(c),
            "ldid_output": o,
            "injected": injected,
            "status": injected ? "still_injected" : "reverted"
        ]
    }

    /// 完全移除：还原 + 删除 dylib 文件
    func remove(bundleId: String) throws -> [String: Any] {
        var r = (try? disable(bundleId: bundleId)) ?? ["action": "remove"]
        if let app = AppCatalog.find(bundleId) {
            let agentDst = (app.path as NSString).appendingPathComponent("TrollMCPAgent.dylib")
            if FileManager.default.fileExists(atPath: agentDst) {
                try? FileManager.default.removeItem(atPath: agentDst)
                r["dylib_removed"] = true
            }
        }
        AuditLog.shared.log("injection.remove", detail: bundleId)
        return r
    }

    /// 检查指定 App 是否已注入
    func inspect(_ bundleId: String) -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        let mainBinary = executablePath(app)
        let backup = mainBinary + ".bak_macho"
        let agentDst = (app.path as NSString).appendingPathComponent("TrollMCPAgent.dylib")
        let injected = isInjected(mainBinary)
        return [
            "app": app.name,
            "bundleId": bundleId,
            "mainBinary": mainBinary,
            "injected": injected,
            "hasBackup": FileManager.default.fileExists(atPath: backup),
            "agentPresent": FileManager.default.fileExists(atPath: agentDst),
            "bundledTools": availableBinaries()
        ]
    }

    /// 列出真正已注入的 App（存在 .bak_macho 备份即代表曾被本工具注入）
    func status() -> [String: Any] {
        let apps = AppCatalog.list()
        var injectedApps: [[String: Any]] = []
        for app in apps {
            let mainBinary = executablePath(app)
            let backup = mainBinary + ".bak_macho"
            if FileManager.default.fileExists(atPath: backup) {
                injectedApps.append([
                    "bundleId": app.bundleId,
                    "name": app.name,
                    "injected": isInjected(mainBinary)
                ])
            }
        }
        return [
            "total_apps": apps.count,
            "bundled_tools": availableBinaries(),
            "injected_count": injectedApps.count,
            "injected_apps": injectedApps
        ]
    }
}
