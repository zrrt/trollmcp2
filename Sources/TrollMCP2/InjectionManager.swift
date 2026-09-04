import Foundation
import Darwin
import UIKit

/// 注入管理器：使用内置 ldid / optool / insert_dylib / ct_bypass 二进制，通过 posix_spawn
/// 真实地把 TrollMCPAgent.dylib 注入到目标 App 主可执行文件（TrollStore 无越狱注入）。
/// v2.9.32：写 bundle 的文件操作全部改 **root 身份**执行（TrollStore TSRootBinaries +
/// persona-mgmt），修复无越狱下 mobile 用户无权写 root 拥有的 app bundle（POSIX 13）。
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

    /// iOS 大版本（用于选择 cp / cp-15 等工具变体）
    private var majorVersion: Int {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion
    }

    /// 选择可用的 coreutils 复制工具：iOS 15 用 cp-15，iOS 16+ 用 cp
    private func cpBinary() -> String? {
        if majorVersion <= 15 { return binaryPath("cp-15") ?? binaryPath("cp") }
        return binaryPath("cp") ?? binaryPath("cp-15")
    }

    private func mvBinary() -> String? {
        if majorVersion <= 15 { return binaryPath("mv-15") ?? binaryPath("mv") }
        return binaryPath("mv") ?? binaryPath("mv-15")
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

    /// v2.9.32：以 **root 身份**执行包内二进制（写 app bundle 必需，mobile 无 POSIX 写权限）。
    /// 依赖 TrollStore 安装时保留的 persona-mgmt entitlement + Info.plist TSRootBinaries 声明。
    @discardableResult
    func runAsRoot(_ name: String, args: [String]) -> (Int32, String) {
        guard let bin = binaryPath(name) else { return (-1, "binary not bundled: \(name)") }
        let result = spawnRoot(bin, args: [name] + args)
        if result.0 != 0, name != "ldid", let ldid = binaryPath("ldid") {
            _ = spawnRoot(ldid, args: ["-S", bin])
            let retry = spawnRoot(bin, args: [name] + args)
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

    /// v2.9.32：root 版 spawn（posix_spawnattr_setuid_np/setgid_np → uid 0）。
    /// 这些 _np 私有函数存在于 libSystem 但未导出到 SDK 链接（编译期 undefined symbol），
    /// 故用 dlsym 运行时动态查找，避免链接失败。iOS 16.3 + persona-mgmt entitlement 下有效。
    func spawnRoot(_ path: String, args: [String]) -> (Int32, String) {
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

        // root 身份：TrollStore 标准做法——persona 99 (root) + OVERRIDE（对齐 TrollFools spawnRoot）
        // v2.9.45：之前用 posix_spawnattr_setuid_np(0) 在 iOS 上不真正生效（setuid 需真正 root 或 persona 机制），
        // 子进程实际仍是 mobile 用户 → 写其他 app bundle 报 EPERM。改用 persona API + com.apple.private.persona-mgmt。
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        typealias SetPersonaFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, UInt32, UInt32) -> Int32
        typealias SetPersonaIdFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, UInt32) -> Int32
        if let lib = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY) {
            if let f = dlsym(lib, "posix_spawnattr_set_persona_np") {
                let fn = unsafeBitCast(f, to: SetPersonaFn.self)
                _ = fn(&attr, 99, 1)   // persona 99 = root；POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE = 1
            }
            if let f = dlsym(lib, "posix_spawnattr_set_persona_uid_np") {
                let fn = unsafeBitCast(f, to: SetPersonaIdFn.self)
                _ = fn(&attr, 0)
            }
            if let f = dlsym(lib, "posix_spawnattr_set_persona_gid_np") {
                let fn = unsafeBitCast(f, to: SetPersonaIdFn.self)
                _ = fn(&attr, 0)
            }
            dlclose(lib)
        }

        var env: [UnsafeMutablePointer<CChar>?] = [
            strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"),
            strdup("HOME=/var/root"),
            strdup("UID=0"),
            nil
        ]
        defer { for p in env where p != nil { free(p) } }

        let status = posix_spawn(&pid, path, &fileActions, &attr, &argv, &env)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
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
            let code = Int32((UInt32(st) >> 8) & 0xff)
            return (code, String(data: out, encoding: .utf8) ?? "")
        }
        close(outPipe[0]); close(errPipe[0])
        return (status, "spawnRoot failed (\(status))")
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
    /// v2.9.32：写 bundle 的文件操作全部改 root 执行（修复 mobile 无 POSIX 写权限 → POSIX 13）。
    /// `dylibSourcePath`：指定本地 dylib 文件（如 GitHub 下载的 CompileProbe.dylib）注入；
    /// 为空时注入内置 TrollMCPAgent.dylib。
    func enable(bundleId: String, dylibName: String = "@executable_path/TrollMCPAgent.dylib",
                dylibSourcePath: String? = nil) throws -> [String: Any] {
        _ = dylibName  // v2.9.45: 注入名由 Frameworks/@rpath 自动决定，保留参数兼容旧调用
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        guard binaryPath("insert_dylib") != nil,
              binaryPath("ldid") != nil,
              let cp = cpBinary() else {
            throw MCPError.failed("insert_dylib / ldid / cp 未内置")
        }
        let mainBinary = executablePath(app)
        guard FileManager.default.fileExists(atPath: mainBinary) else {
            throw MCPError.failed("主二进制不存在: \(mainBinary)")
        }
        // 决定注入源 dylib 与目标 load name
        let agentSrc: String
        let sourceFileName: String
        if let src = dylibSourcePath, !src.isEmpty {
            guard FileManager.default.fileExists(atPath: src) else {
                throw MCPError.failed("指定的 dylib 文件不存在: \(src)")
            }
            agentSrc = src
            sourceFileName = (src as NSString).lastPathComponent
        } else {
            // v2.9.21：agent dylib 在 bin/ 子目录（build-ipa.sh 把 Resources/bin 拷成 app/bin）
            agentSrc = binDir.appendingPathComponent("TrollMCPAgent.dylib").path
            guard FileManager.default.fileExists(atPath: agentSrc) else {
                throw MCPError.failed("TrollMCPAgent.dylib 未内置（\(agentSrc)）")
            }
            sourceFileName = "TrollMCPAgent.dylib"
        }

        // v2.9.45：对齐 TrollFools —— 目标优先放 Frameworks/（@rpath 加载），无 Frameworks 才放 app 根目录（@executable_path）
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        let useFramework = FileManager.default.fileExists(atPath: frameworksDir)
        let agentDst = useFramework
            ? (frameworksDir as NSString).appendingPathComponent(sourceFileName)
            : (app.path as NSString).appendingPathComponent(sourceFileName)
        let injectName = useFramework ? "@rpath/\(sourceFileName)" : "@executable_path/\(sourceFileName)"

        // v2.9.45：预处理源 dylib（仅用户下载的、可写路径）——ct_bypass 加 CoreTrust 签名 + chown 33:33，
        // 确保目标 App 能通过签名校验加载该 dylib（对齐 TrollFools：先 chown & ct_bypass 再 cp）
        if let src = dylibSourcePath, !src.isEmpty {
            let teamID = "TROLLTROLL"
            let (cc, oc) = runAsRoot("ct_bypass", args: ["-r", "-i", agentSrc, "-t", teamID])
            if cc != 0 { AuditLog.shared.log("injection.ct_bypass.dylib", detail: "exit=\(cc) \(oc)") }
            let (ch, oh) = runAsRoot("chown", args: ["33:33", agentSrc])
            if ch != 0 { AuditLog.shared.log("injection.chown.dylib", detail: "exit=\(ch) \(oh)") }
        }

        // 1. root 拷贝 agent dylib 进目标 App（对齐 TrollFools 先清理旧文件再拷）
        if FileManager.default.fileExists(atPath: agentDst) {
            _ = runAsRoot("rm", args: ["-rf", agentDst])
        }
        let (c0, o0) = runAsRoot("cp", args: ["-a", agentSrc, agentDst])
        if c0 != 0 { throw MCPError.failed("root cp agent 失败(\(c0)): \(o0)") }
        _ = runAsRoot("chown", args: ["33:33", agentDst])

        // 2. root 备份原始主二进制
        let backup = mainBinary + ".bak_macho"
        if !FileManager.default.fileExists(atPath: backup) {
            let (cB, oB) = runAsRoot("cp", args: ["-a", mainBinary, backup])
            if cB != 0 { throw MCPError.failed("root cp 备份主二进制失败(\(cB)): \(oB)") }
        }

        // 3. root insert_dylib --inplace
        let (c1, o1) = runAsRoot("insert_dylib", args: ["--inplace", injectName, mainBinary])
        guard c1 == 0 else {
            throw MCPError.failed("insert_dylib 失败(\(c1)): \(o1)")
        }

        // 4. root ldid -S 重签（无 entitlements）
        let (c2, o2) = runAsRoot("ldid", args: ["-S", mainBinary])

        // v2.9.45：5. root ct_bypass 目标 Mach-O（CoreTrust 绕过，对齐 TrollFools）。
        // TrollStore App 修改 Mach-O 后必须 ct_bypass 重签，否则 AMFI 校验失败、目标 App 无法启动/不加载 dylib。
        let teamID = "TROLLTROLL"
        let (c3, o3) = runAsRoot("ct_bypass", args: ["-r", "-i", mainBinary, "-t", teamID])

        // v2.9.32：injected 判定——insert_dylib 成功（exit 0）即视为已注入。
        // 自定义 dylib（如 CompileProbe.dylib）不匹配 "TrollMCPAgent" 字符串扫描，
        // 因此不能只靠 isInjected；备份存在 + insert 成功 = 注入已写入。
        let inserted = c1 == 0
        let injected = inserted || isInjected(mainBinary)
        AuditLog.shared.log("injection.enable", detail: "\(bundleId) → \(mainBinary) injected=\(injected)")
        return [
            "action": "inject",
            "app": app.name,
            "bundleId": bundleId,
            "mainBinary": mainBinary,
            "dylib": injectName,
            "dylibSource": agentSrc,
            "dylibDst": agentDst,
            "backup": backup,
            "root": true,
            "insert_dylib_exit": Int(c1),
            "ldid_exit": Int(c2),
            "ct_bypass_exit": Int(c3),
            "insert_output": o1,
            "ldid_output": o2,
            "ct_bypass_output": o3,
            "injected": injected,
            "status": injected ? "injected" : "injection_failed"
        ]
    }

    /// 还原注入（用备份覆盖主二进制），保留 dylib 文件
    /// v2.9.32：root 执行 rm + cp + ldid。
    func disable(bundleId: String) throws -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        let mainBinary = executablePath(app)
        let backup = mainBinary + ".bak_macho"
        guard FileManager.default.fileExists(atPath: backup) else {
            throw MCPError.failed("未找到注入备份，可能从未注入或无法还原")
        }
        guard let cp = cpBinary() else { throw MCPError.failed("cp 未内置") }
        let (cR, oR) = runAsRoot("rm", args: ["-f", mainBinary])
        if cR != 0 { throw MCPError.failed("root rm 失败(\(cR)): \(oR)") }
        let (cC, oC) = runAsRoot("cp", args: ["-a", backup, mainBinary])
        if cC != 0 { throw MCPError.failed("root cp 还原失败(\(cC)): \(oC)") }
        let (c, o) = runAsRoot("ldid", args: ["-S", mainBinary])
        let injected = isInjected(mainBinary)
        AuditLog.shared.log("injection.disable", detail: bundleId)
        return [
            "action": "remove",
            "bundleId": bundleId,
            "restored_from_backup": true,
            "root": true,
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
            // v2.9.45：dylib 可能在 Frameworks/ 或 app 根目录，两处都检查
            let candidates = [
                (app.path as NSString).appendingPathComponent("TrollMCPAgent.dylib"),
                (app.path as NSString).appendingPathComponent("Frameworks/TrollMCPAgent.dylib")
            ]
            for p in candidates where FileManager.default.fileExists(atPath: p) {
                let (cD, oD) = runAsRoot("rm", args: ["-f", p])
                r["dylib_removed"] = cD == 0
                r["rm_output"] = oD
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
            "injected_apps": injectedApps,
            // v2.9.40：引导 AI 拿具体 Bundle ID（用户反馈 AI 只用 status 查不到 ID 卡住）
            "hint": "要获取具体 App 的 bundle_id + 名称，请调用 injection.list"
        ]
    }
}
