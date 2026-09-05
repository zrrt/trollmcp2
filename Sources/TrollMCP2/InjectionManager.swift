import Foundation
import Darwin
import UIKit

// v2.9.52：对照 TrollStore 官方 TSUtil.m，用 @_silgen_name 编译时链接 persona 函数。
// 之前用 dlsym(nil, ...) 运行时查找，但这些符号在 iOS 上是隐藏符号，dlsym 全返回 nil，
// 导致 persona 99+uid0+gid0 根本没设置上，euid 恒为 501，cp 写 root 目录 EPERM。
// 编译时链接后，只要 App 有 com.apple.private.persona-mgmt entitlement，就能以 root spawn。
@_silgen_name("posix_spawnattr_set_persona_np")
private func posix_spawnattr_set_persona_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ persona: UInt32, _ flags: UInt32) -> Int32
@_silgen_name("posix_spawnattr_set_persona_uid_np")
private func posix_spawnattr_set_persona_uid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ uid: UInt32) -> Int32
@_silgen_name("posix_spawnattr_set_persona_gid_np")
private func posix_spawnattr_set_persona_gid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ gid: UInt32) -> Int32
private let POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE: UInt32 = 1

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

    /// v2.9.52：root 版 spawn（真正修复版）。
    /// 对照 TrollStore 官方 TSUtil.m spawnRoot：persona 99 + uid=0 + gid=0，编译时链接（@_silgen_name）。
    /// 之前用 dlsym 运行时查找，iOS 上这些是隐藏符号，dlsym 全返回 nil → persona 没设置 → euid=501 → EPERM。
    /// 编译时链接后直接调用，有 persona-mgmt entitlement 即可 root spawn，不依赖 TSRootBinaries setuid 位。
    /// v2.9.57：完全重写，对齐 TrollFools AuxiliaryExecute+Spawn.swift：
    /// - 非阻塞 pipe（fcntl O_NONBLOCK），避免子进程输出满缓冲区时死锁
    /// - DispatchSource.makeReadSource 异步读取 stdout/stderr
    /// - DispatchSource.makeProcessSource 异步等待进程退出
    /// - 对外保持同步接口（DispatchSemaphore 等待）
    /// - args 已由 runAsRoot 加上工具名作为 argv[0]
    func spawnRoot(_ path: String, args: [String]) -> (Int32, String) {
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var binSetuid = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mode = attrs[.posixPermissions] as? Int {
            binSetuid = (mode & 0o4000) != 0 ? 1 : 0
        }

        // 非阻塞 pipe
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        pipe(&outPipe)
        pipe(&errPipe)
        fcntl(outPipe[0], F_SETFL, O_NONBLOCK)
        fcntl(errPipe[0], F_SETFL, O_NONBLOCK)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        let rPersona = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)
        let rUid = posix_spawnattr_set_persona_uid_np(&attr, 0)
        let rGid = posix_spawnattr_set_persona_gid_np(&attr, 0)
        defer { posix_spawnattr_destroy(&attr) }

        let diagPrefix = "[bin-setuid=\(binSetuid) proc-euid=\(geteuid()) persona_r=\(rPersona) uid_r=\(rUid) gid_r=\(rGid)] "

        // 环境变量：继承当前环境 + DISABLE_TWEAKS=1 + PATH
        var envBuilder = [String: String]()
        var currentEnv = environ
        while let rawStr = currentEnv.pointee {
            defer { currentEnv += 1 }
            let str = String(cString: rawStr)
            if let eq = str.firstIndex(of: "=") {
                envBuilder[String(str[..<eq])] = String(str[str.index(after: eq)...])
            }
        }
        envBuilder["DISABLE_TWEAKS"] = "1"
        envBuilder["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        var env: [UnsafeMutablePointer<CChar>?] = envBuilder.map { strdup("\($0.key)=\($0.value)") }
        env.append(nil)
        defer { for p in env where p != nil { free(p) } }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, path, &fileActions, &attr, argv, env)
        guard spawnStatus == 0 else {
            close(outPipe[0]); close(outPipe[1])
            close(errPipe[0]); close(errPipe[1])
            return (spawnStatus, diagPrefix + "spawnRoot failed (\(spawnStatus))")
        }

        close(outPipe[1]); close(errPipe[1])

        let sema = DispatchSemaphore(value: 0)
        var output = ""
        let outputLock = NSLock()
        let bufsiz = 65536

        let outSource = DispatchSource.makeReadSource(fileDescriptor: outPipe[0], queue: .global())
        let errSource = DispatchSource.makeReadSource(fileDescriptor: errPipe[0], queue: .global())
        let outSem = DispatchSemaphore(value: 0)
        let errSem = DispatchSemaphore(value: 0)

        outSource.setCancelHandler { close(outPipe[0]); outSem.signal() }
        errSource.setCancelHandler { close(errPipe[0]); errSem.signal() }

        outSource.setEventHandler {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsiz)
            defer { buf.deallocate() }
            let n = read(outPipe[0], buf, bufsiz)
            guard n > 0 else {
                if n == -1 && errno == EAGAIN { return }
                outSource.cancel()
                return
            }
            let arr = Array(UnsafeBufferPointer(start: buf, count: n)) + [UInt8(0)]
            arr.withUnsafeBufferPointer { ptr in
                let s = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                outputLock.lock(); output += s; outputLock.unlock()
            }
        }
        errSource.setEventHandler {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsiz)
            defer { buf.deallocate() }
            let n = read(errPipe[0], buf, bufsiz)
            guard n > 0 else {
                if n == -1 && errno == EAGAIN { return }
                errSource.cancel()
                return
            }
            let arr = Array(UnsafeBufferPointer(start: buf, count: n)) + [UInt8(0)]
            arr.withUnsafeBufferPointer { ptr in
                let s = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                outputLock.lock(); output += s; outputLock.unlock()
            }
        }
        outSource.resume()
        errSource.resume()

        var exitCode: Int32 = -1
        let procSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        procSource.setEventHandler {
            var st: Int32 = 0
            var wr: Int32 = 0
            repeat { wr = waitpid(pid, &st, 0) } while wr == -1 && errno == EINTR
            procSource.cancel()
            outSem.wait()
            errSem.wait()
            exitCode = Int32((UInt32(st) >> 8) & 0xff)
            sema.signal()
        }
        procSource.resume()
        sema.wait()

        return (exitCode, diagPrefix + output)
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

    /// 注入 dylib 到指定 App
    /// v2.9.57：完全对齐 TrollFools 注入流程——杀进程→cp --reflink=auto -rfp→备份→LC_RPATH→insert_dylib→ldid保留entitlements→ct_bypass→chown
    func enable(bundleId: String, dylibName: String = "@executable_path/TrollMCPAgent.dylib",
                dylibSourcePath: String? = nil) throws -> [String: Any] {
        _ = dylibName
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        guard binaryPath("insert_dylib") != nil,
              binaryPath("ldid") != nil,
              binaryPath("install_name_tool") != nil,
              let cp = cpBinary() else {
            throw MCPError.failed("insert_dylib / ldid / install_name_tool / cp 未内置")
        }
        let mainBinary = executablePath(app)
        guard FileManager.default.fileExists(atPath: mainBinary) else {
            throw MCPError.failed("主二进制不存在: \(mainBinary)")
        }

        // v2.9.57：0. 杀目标进程（对齐 TrollFools terminateApp），避免文件被占用
        let executableName = (mainBinary as NSString).lastPathComponent
        _ = spawnRoot("/usr/bin/killall", args: ["killall", "-9", executableName])

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
            agentSrc = binDir.appendingPathComponent("TrollMCPAgent.dylib").path
            guard FileManager.default.fileExists(atPath: agentSrc) else {
                throw MCPError.failed("TrollMCPAgent.dylib 未内置（\(agentSrc)）")
            }
            sourceFileName = "TrollMCPAgent.dylib"
        }

        // 目标优先放 Frameworks/（@rpath 加载），无 Frameworks 才放 app 根目录
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        let useFramework = FileManager.default.fileExists(atPath: frameworksDir)
        let agentDst = useFramework
            ? (frameworksDir as NSString).appendingPathComponent(sourceFileName)
            : (app.path as NSString).appendingPathComponent(sourceFileName)
        let injectName = useFramework ? "@rpath/\(sourceFileName)" : "@executable_path/\(sourceFileName)"

        // 预处理源 dylib：ct_bypass + chown 33:33（对齐 TrollFools）
        if let src = dylibSourcePath, !src.isEmpty {
            let teamID = "TROLLTROLL"
            let (cc, oc) = runAsRoot("ct_bypass", args: ["-r", "-i", agentSrc, "-t", teamID])
            if cc != 0 { AuditLog.shared.log("injection.ct_bypass.dylib", detail: "exit=\(cc) \(oc)") }
            let (ch, oh) = runAsRoot("chown", args: ["33:33", agentSrc])
            if ch != 0 { AuditLog.shared.log("injection.chown.dylib", detail: "exit=\(ch) \(oh)") }
        }

        // 1. cp --reflink=auto -rfp（对齐 TrollFools：clone 优先，失败回退普通拷贝）
        if FileManager.default.fileExists(atPath: agentDst) {
            _ = runAsRoot("rm", args: ["-rf", agentDst])
        }
        let (c0, o0) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", agentSrc, agentDst])
        if c0 != 0 { throw MCPError.failed("root cp agent 失败(\(c0)): \(o0)") }
        _ = runAsRoot("chown", args: ["33:33", agentDst])

        // 2. 备份原始主二进制
        let backup = mainBinary + ".bak_macho"
        if !FileManager.default.fileExists(atPath: backup) {
            let (cB, oB) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", mainBinary, backup])
            if cB != 0 { throw MCPError.failed("root cp 备份主二进制失败(\(cB)): \(oB)") }
        }

        // 3. LC_RPATH：添加 @executable_path/Frameworks（对齐 TrollFools cmdInsertLoadCommandRuntimePath）
        // 先用 install_name_tool -add_rpath，失败说明已存在或不支持，忽略
        var rpathExit: Int32 = -1
        var rpathOutput = ""
        if useFramework {
            let (r, o) = runAsRoot("install_name_tool", args: ["-add_rpath", "@executable_path/Frameworks", mainBinary])
            rpathExit = r; rpathOutput = o
        }

        // 4. insert_dylib（对齐 TrollFools 参数顺序）
        let (c1, o1) = runAsRoot("insert_dylib", args: [injectName, mainBinary, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes"])
        guard c1 == 0 else {
            throw MCPError.failed("insert_dylib 失败(\(c1)): \(o1)")
        }

        // 5. ldid 保留 entitlements（对齐 TrollFools cmdPseudoSign）：
        // 先 ldid -e 导出原 entitlements，再 ldid -Sxml 签回，避免丢失主二进制的私有 entitlement
        let tmpEnt = NSTemporaryDirectory().appending("trollmcp2_\(UUID().uuidString).xml")
        let (c2e, o2e) = runAsRoot("ldid", args: ["-e", mainBinary])
        var ldidExit: Int32 = 0
        var ldidOutput = ""
        if c2e == 0, !o2e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let xmlData = o2e.data(using: .utf8), xmlData.contains("<?xml") {
            // 导出成功且是有效 XML，写临时文件后签回
            try? xmlData.write(to: URL(fileURLWithPath: tmpEnt))
            let (c2s, o2s) = runAsRoot("ldid", args: ["-S\(tmpEnt)", mainBinary])
            ldidExit = c2s; ldidOutput = o2s
            try? FileManager.default.removeItem(atPath: tmpEnt)
        } else {
            // 导出失败或空，用普通 -S
            let (c2s, o2s) = runAsRoot("ldid", args: ["-S", mainBinary])
            ldidExit = c2s; ldidOutput = o2s
        }

        // 6. ct_bypass 目标 Mach-O（CoreTrust 绕过）
        let teamID = "TROLLTROLL"
        let (c3, o3) = runAsRoot("ct_bypass", args: ["-r", "-i", mainBinary, "-t", teamID])

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
            "killed_process": executableName,
            "rpath_exit": Int(rpathExit),
            "rpath_output": rpathOutput,
            "insert_dylib_exit": Int(c1),
            "ldid_exit": Int(ldidExit),
            "ct_bypass_exit": Int(c3),
            "insert_output": o1,
            "ldid_output": ldidOutput,
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
        let (cC, oC) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", backup, mainBinary])
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
