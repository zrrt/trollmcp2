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

// MARK: - v2.9.89 Mach-O 分析器（对齐 TrollFools 注入策略：选未加密可注入目标 + 备份 diff）

/// 轻量 Mach-O 解析：magic / 架构 / 加密状态（LC_ENCRYPTION_INFO cryptid）/ 加载的 dylib 列表。
/// 支持 thin（32/64）与 fat（大端，自动定位 arm64 slice）。
enum MachOAnalyzer {
    struct Info {
        var arch: String
        var cryptID: UInt32
        var dylibs: [String]
        var valid: Bool
    }

    static let lcLoadDylib: UInt32 = 0x0C
    static let lcLoadWeakDylib: UInt32 = 0x80000018
    static let lcLoadUpwardDylib: UInt32 = 0x23
    static let lcEncryptionInfo: UInt32 = 0x21
    static let lcEncryptionInfo64: UInt32 = 0x2C

    /// 解析 Mach-O 信息；非 Mach-O 或读取失败返回 nil
    static func analyze(_ path: String) -> Info? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count >= 8 else { return nil }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }

        var offset = 0
        var effectiveMagic = magic

        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            // fat：按大端读 nfat_arch，找 arm64（cputype=0x0100000C）slice
            let countRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let count = magic == 0xCAFEBABE ? countRaw.byteSwapped : countRaw
            var foundSlice: (off: UInt32, size: UInt32)?
            for i in 0..<min(count, 16) {
                let off = 8 + Int(i) * 20
                guard data.count >= off + 16 else { break }
                let cpuRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
                let cpu = magic == 0xCAFEBABE ? cpuRaw.byteSwapped : cpuRaw
                let sliceOffRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self) }
                let sliceOff = magic == 0xCAFEBABE ? sliceOffRaw.byteSwapped : sliceOffRaw
                if cpu == 0x0100000C {   // arm64
                    foundSlice = (sliceOff, 0)
                    break
                }
            }
            guard let f = foundSlice else {
                return Info(arch: "fat(no-arm64)", cryptID: 0, dylibs: [], valid: false)
            }
            offset = Int(f.off)
            guard data.count >= offset + 8 else { return nil }
            effectiveMagic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }

        let is64 = effectiveMagic == 0xFEEDFACF
        let is32 = effectiveMagic == 0xFEEDFACE
        guard is64 || is32 else {
            return Info(arch: "not-macho", cryptID: 0, dylibs: [], valid: false)
        }
        let headerSize = is64 ? 32 : 28
        guard data.count >= offset + headerSize else { return nil }

        let ncmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self) }
        let sizeofcmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 20, as: UInt32.self) }

        var cryptID: UInt32 = 0
        var dylibs: [String] = []
        var cursor = offset + headerSize
        let cmdEnd = offset + headerSize + Int(sizeofcmds)
        var remain = Int(ncmds)
        while cursor + 8 <= cmdEnd, remain > 0, data.count >= cursor + 8 {
            let cmd = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
            let cmdsizeRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self) }
            let cmdsize = Int(cmdsizeRaw)
            guard cmdsize >= 8, cursor + cmdsize <= cmdEnd, data.count >= cursor + cmdsize else { break }
            switch cmd {
            case lcLoadDylib, lcLoadWeakDylib, lcLoadUpwardDylib:
                if cursor + 12 <= data.count {
                    let nameOff = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 8, as: UInt32.self) })
                    let nameStart = cursor + nameOff
                    if nameStart < data.count {
                        var name = ""
                        var i = nameStart
                        while i < data.count, i < nameStart + 512 {
                            let b = data[i]
                            if b == 0 { break }
                            name.append(Character(UnicodeScalar(b)))
                            i += 1
                        }
                        if !name.isEmpty { dylibs.append(name) }
                    }
                }
            case lcEncryptionInfo, lcEncryptionInfo64:
                if cursor + 20 <= data.count {
                    cryptID = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 16, as: UInt32.self) }
                }
            default:
                break
            }
            cursor += cmdsize
            remain -= 1
        }
        return Info(arch: is64 ? "arm64" : "arm32", cryptID: cryptID, dylibs: dylibs, valid: true)
    }

    /// 是否已加密（App Store 加密二进制 cryptid=1，注入会破坏它 → 必须跳过）
    static func isProtected(_ path: String) -> Bool {
        guard let info = analyze(path) else { return true }
        return info.cryptID != 0
    }

    /// 是否合法可注入的 Mach-O
    static func isInjectiveMachO(_ path: String) -> Bool {
        guard let info = analyze(path) else { return false }
        return info.valid && (info.arch == "arm64" || info.arch == "arm32" || info.arch.hasPrefix("fat")) && info.cryptID == 0
    }
}

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
        _ = fcntl(outPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(errPipe[0], F_SETFL, O_NONBLOCK)

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

        // v2.9.63：用 waitpid 同步等待进程结束，替代 DispatchSource.makeProcessSource。
        // 原实现有竞态：/usr/bin/id 等快速命令在 procSource.resume() 前就退出，.exit 事件丢失，
        // exitCode 停在初始值 -1，导致 Entitlements 检测误报"未生效"。
        var st: Int32 = 0
        var wr: Int32 = 0
        repeat { wr = waitpid(pid, &st, 0) } while wr == -1 && errno == EINTR
        // 进程已退出，等待 pipe 数据全部读完
        outSem.wait()
        errSem.wait()
        let exitCode = Int32((UInt32(st) >> 8) & 0xff)

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

    /// 高危 App 前缀（v2.9.89 高危护栏）：微信/支付宝/系统/银行等注入风险高，注入前强制提醒
    static let sensitiveBundleHints = [
        "com.tencent.mm", "com.tencent.xin", "com.alipay", "com.apple",
        "com.unionpay", "com.ccb", "com.icbc", "com.cmbchina", "com.bank",
        "com.paypal", "com.apple.mobilesafari", "com.tencent.wework",
    ]

    static func isSensitive(_ bundleId: String) -> Bool {
        sensitiveBundleHints.contains { bundleId.lowercased().hasPrefix($0) }
    }

    /// 是否为系统/越狱基础库（清理残留时不能删这些）
    static func isSensitiveSystemLibrary(_ itemName: String) -> Bool {
        let lower = itemName.lowercased()
        if lower.hasPrefix("libswift") { return true }
        let names = ["cydiasubstrate", "ellekit", "libsubstrate", "libsubstitute",
                     "libellekit", "substitute", "libhooker", "libjailbreak"]
        return names.contains { lower.contains($0) }
    }

    /// 注入资产忽略名单（对齐 TrollFools ignoredDylibAndFrameworkNames）
    private static let ignoredDylibNames: Set<String> = [
        "cydiasubstrate", "cydiasubstrate.framework", "ellekit", "ellekit.framework",
        "libsubstrate.dylib", "libsubstitute.dylib", "libellekit.dylib",
    ]

    // MARK: 备份辅助（对齐 TrollFools：备份后缀 .troll-fools.bak）

    private func alternateURL(for target: String) -> String {
        target + ".troll-fools.bak"
    }

    private func hasAlternate(_ target: String) -> Bool {
        FileManager.default.fileExists(atPath: alternateURL(for: target)) ||
        FileManager.default.fileExists(atPath: target + ".bak_macho")   // 旧格式兼容
    }

    @discardableResult
    private func makeAlternate(_ target: String) throws -> String {
        let alt = alternateURL(for: target)
        if !FileManager.default.fileExists(atPath: alt) {
            let (c, o) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", target, alt])
            if c != 0 { throw MCPError.failed("root cp 备份失败(\(c)): \(o)") }
        }
        return alt
    }

    /// 从备份恢复（优先新格式 .troll-fools.bak，兼容旧 .bak_macho），成功后删备份
    @discardableResult
    func restoreAlternate(_ target: String) throws -> Bool {
        let alt = alternateURL(for: target)
        let legacy = target + ".bak_macho"
        let backupPath: String
        if FileManager.default.fileExists(atPath: alt) {
            backupPath = alt
        } else if FileManager.default.fileExists(atPath: legacy) {
            backupPath = legacy
        } else {
            return false
        }
        guard let cp = cpBinary() else { throw MCPError.failed("cp 未内置") }
        _ = runAsRoot("rm", args: ["-f", target])
        let (c, o) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", backupPath, target])
        if c != 0 { throw MCPError.failed("root cp 恢复失败(\(c)): \(o)") }
        _ = runAsRoot("rm", args: ["-f", backupPath])
        return true
    }

    // MARK: Mach-O 收集（对齐 TrollFools frameworkMachOsInBundle + locateAvailableMachO）

    /// 收集可注入 Mach-O：Frameworks/ 下未加密 dylib（字典序），主二进制垫底。
    /// 跳过：非 Mach-O、加密段（cryptid!=0）、忽略名单、备份文件、已注入资产文件。
    func collectInjectableMachOs(_ app: AppCatalog.AppEntry) -> [String] {
        var candidates: [String] = []
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworksDir),
           let items = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            for item in items.sorted() {
                let full = (frameworksDir as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                let lower = item.lowercased()
                // 跳过备份文件、忽略名单、非 dylib 目录
                if item.hasSuffix(".troll-fools.bak") || item.hasSuffix(".bak_macho") { continue }
                if Self.ignoredDylibNames.contains(lower) { continue }
                if lower.hasPrefix("libswift") { continue }
                if isDir.boolValue {
                    // .framework 目录：解析内部可执行文件
                    if lower.hasSuffix(".framework") {
                        let exeName = (item as NSString).deletingPathExtension
                        let exe = (full as NSString).appendingPathComponent(exeName)
                        if MachOAnalyzer.isInjectiveMachO(exe) { candidates.append(exe) }
                    }
                    continue
                }
                if lower.hasSuffix(".dylib"), MachOAnalyzer.isInjectiveMachO(full) {
                    candidates.append(full)
                }
            }
        }
        // 主二进制垫底（TrollFools 默认 preferMainExecutable=false）
        let main = executablePath(app)
        if MachOAnalyzer.isInjectiveMachO(main) { candidates.append(main) }
        return candidates
    }

    /// 注入资产列表（对齐 TrollFools injectedDylibAndFrameworkURLsInBundle）：
    /// Frameworks/ 下非系统 dylib + 带 .troll-fools 标记的 framework/bundle
    func injectedAssets(in app: AppCatalog.AppEntry) -> [String] {
        var assets: [String] = []
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworksDir),
           let items = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            for item in items {
                let full = (frameworksDir as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                let lower = item.lowercased()
                if lower.hasPrefix("libswift") || Self.ignoredDylibNames.contains(lower) { continue }
                if item.hasSuffix(".troll-fools.bak") || item.hasSuffix(".bak_macho") { continue }
                if lower.hasSuffix(".dylib"), !isDir.boolValue {
                    assets.append(full)
                } else if lower.hasSuffix(".framework") || lower.hasSuffix(".bundle") {
                    // 只有带注入标记的才算（.troll-fools 文件）
                    let marker = (full as NSString).appendingPathComponent(".troll-fools")
                    if FileManager.default.fileExists(atPath: marker) { assets.append(full) }
                }
            }
        }
        return assets.sorted()
    }

    /// 收集被修改过的 Mach-O（有备份的）：主二进制 + Frameworks 下所有 dylib
    func collectModifiedMachOs(_ app: AppCatalog.AppEntry) -> [String] {
        var modified: [String] = []
        let main = executablePath(app)
        if hasAlternate(main) { modified.append(main) }
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworksDir),
           let items = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            for item in items {
                let full = (frameworksDir as NSString).appendingPathComponent(item)
                if item.hasSuffix(".troll-fools.bak") || item.hasSuffix(".bak_macho") { continue }
                if hasAlternate(full) { modified.append(full) }
            }
        }
        return modified
    }

    /// 移除指定资产的加载命令（对齐 TrollFools optool uninstall）
    private func removeLoadCommand(assetName: String, from target: String) -> (Int32, String) {
        runAsRoot("optool", args: ["uninstall", "-p", assetName, "-t", target])
    }

    /// 伪签（对齐 TrollFools cmdPseudoSign：改 Mach-O 前必须 ldid -S，否则 __LINKEDIT 顺序问题）
    @discardableResult
    private func pseudoSign(_ target: String) -> (Int32, String) {
        runAsRoot("ldid", args: ["-S", target])
    }

    /// CoreTrust 重签 + 属主（对齐 TrollFools cmdCoreTrustBypass + cmdChangeOwnerToInstalld）
    @discardableResult
    private func coreTrustBypass(_ target: String) -> (Int32, String) {
        let (c, o) = runAsRoot("ct_bypass", args: ["-r", "-i", target, "-t", "TROLLTROLL"])
        _ = runAsRoot("chown", args: ["33:33", target])
        return (c, o)
    }

    /// 注入 dylib 到指定 App
    /// v2.9.89：完全对齐 TrollFools InjectorV3 策略——
    /// 目标默认选 Frameworks/ 内未加密可注入 Mach-O（不直接改主二进制），
    /// 备份 .troll-fools.bak（TrollFools 可识别），每步改前 ldid 伪签，任一步失败自动回滚。
    func enable(bundleId: String, dylibName: String = "@executable_path/TrollMCPAgent.dylib",
                dylibSourcePath: String? = nil) throws -> [String: Any] {
        _ = dylibName
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        guard binaryPath("insert_dylib") != nil,
              binaryPath("ldid") != nil,
              binaryPath("install_name_tool") != nil,
              binaryPath("optool") != nil,
              binaryPath("ct_bypass") != nil,
              cpBinary() != nil else {
            throw MCPError.failed("insert_dylib / ldid / install_name_tool / optool / ct_bypass / cp 未内置")
        }

        // 0. 高危护栏：敏感 App 注入前强制提醒（不阻断，AI 需看到风险并先 diagnose）
        let sensitive = Self.isSensitive(bundleId)

        // 1. 决定注入源 dylib 与目标 load name
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

        // 2. 选注入目标 Mach-O：Frameworks 内未加密优先，主二进制垫底（对齐 TrollFools）
        let candidates = collectInjectableMachOs(app)
        guard !candidates.isEmpty else {
            throw MCPError.failed("没有可注入的 Mach-O：目标 App 的二进制全部加密或不可读（App Store 加密 App 无法注入）")
        }
        let targetMachO = candidates[0]
        let targetIsMain = targetMachO == executablePath(app)

        // 3. 杀目标进程（对齐 TrollFools terminateApp）
        let executableName = (executablePath(app) as NSString).lastPathComponent
        _ = spawnRoot("/usr/bin/killall", args: ["killall", "-9", executableName])

        // 4. 预处理源 dylib：ct_bypass + chown（对齐 TrollFools applyCoreTrustBypass）
        let (pc, po) = runAsRoot("ct_bypass", args: ["-r", "-i", agentSrc, "-t", "TROLLTROLL"])
        if pc != 0 { AuditLog.shared.log("injection.ct_bypass.dylib", detail: "exit=\(pc) \(po)") }
        _ = runAsRoot("chown", args: ["33:33", agentSrc])

        // 5. 拷贝 dylib 到 Frameworks/（无 Frameworks 才放 app 根）
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        let useFramework = FileManager.default.fileExists(atPath: frameworksDir)
        let agentDst = useFramework
            ? (frameworksDir as NSString).appendingPathComponent(sourceFileName)
            : (app.path as NSString).appendingPathComponent(sourceFileName)
        let injectName = useFramework ? "@rpath/\(sourceFileName)" : "@executable_path/\(sourceFileName)"
        if FileManager.default.fileExists(atPath: agentDst) {
            _ = runAsRoot("rm", args: ["-rf", agentDst])
        }
        let (c0, o0) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", agentSrc, agentDst])
        if c0 != 0 { throw MCPError.failed("root cp agent 失败(\(c0)): \(o0)") }
        _ = runAsRoot("chown", args: ["33:33", agentDst])

        // 6. 备份目标 Mach-O（对齐 TrollFools makeAlternate：.troll-fools.bak）
        let backup = try makeAlternate(targetMachO)

        // 7. 注入链：改前伪签 → rpath → insert_dylib → 重签 → 验证；任一步失败自动回滚
        var rpathExit: Int32 = -1
        var rpathOutput = ""
        var insertExit: Int32 = -1
        var insertOutput = ""
        do {
            // 7a. 改前伪签（对齐 TrollFools cmdPseudoSign force）——修掉 install_name_tool LINKEDIT 报错
            let (ps, pso) = pseudoSign(targetMachO)
            if ps != 0 { AuditLog.shared.log("injection.presign", detail: "exit=\(ps) \(pso)") }

            // 7b. LC_RPATH：对齐 TrollFools cmdInsertLoadCommandRuntimePath——
            // 目标 Mach-O 统一加 @executable_path/Frameworks（@executable_path 始终指向 App 根目录）
            if useFramework {
                let (r, o) = runAsRoot("install_name_tool", args: ["-add_rpath", "@executable_path/Frameworks", targetMachO])
                rpathExit = r; rpathOutput = o
                if r != 0 {
                    // 已有该 rpath 或 App Store 加密段未重签；insert_dylib 前已伪签，继续不阻断
                    AuditLog.shared.log("injection.rpath", detail: "exit=\(r) \(o)")
                }
            }

            // 7c. insert_dylib（对齐 TrollFools 参数）
            let (c1, o1) = runAsRoot("insert_dylib", args: [injectName, targetMachO, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes"])
            insertExit = c1; insertOutput = o1
            guard c1 == 0 else {
                throw MCPError.failed("insert_dylib 失败(\(c1)): \(o1)")
            }

            // 7d. 重签：ldid -S + ct_bypass + chown
            _ = pseudoSign(targetMachO)
            _ = coreTrustBypass(targetMachO)

            // 7e. 验证：加载命令已写入 + Mach-O 结构有效
            let verifyInfo = MachOAnalyzer.analyze(targetMachO)
            let loadOK = verifyInfo?.dylibs.contains(injectName) ?? false
            let structOK = verifyInfo?.valid ?? false
            if !loadOK || !structOK {
                throw MCPError.failed("注入后验证失败: loadCommand=\(loadOK) macho=\(structOK)")
            }
        } catch {
            // 失败自动回滚：恢复目标 Mach-O + 删掉已拷贝 dylib（对齐 TrollFools restoreAlternate + batchRemove）
            var rollbackLog: [String: Any] = ["triggered": true]
            do {
                rollbackLog["restored"] = try restoreAlternate(targetMachO)
            } catch {
                rollbackLog["restore_error"] = "\(error)"
            }
            if FileManager.default.fileExists(atPath: agentDst) {
                _ = runAsRoot("rm", args: ["-rf", agentDst])
                rollbackLog["dylib_removed"] = true
            }
            let wrapped = NSError(domain: "InjectionManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(error.localizedDescription)（已自动回滚）"])
            AuditLog.shared.log("injection.enable.rollback", detail: "\(bundleId) \(wrapped.localizedDescription)")
            throw wrapped
        }

        let injected = MachOAnalyzer.analyze(targetMachO)?.dylibs.contains(injectName) ?? false
        AuditLog.shared.log("injection.enable", detail: "\(bundleId) → \(targetMachO) injected=\(injected)")
        return [
            "action": "inject",
            "app": app.name,
            "bundleId": bundleId,
            "target_macho": targetMachO,
            "target_is_main": targetIsMain,
            "mainBinary": executablePath(app),
            "dylib": injectName,
            "dylibSource": agentSrc,
            "dylibDst": agentDst,
            "backup": backup,
            "root": true,
            "killed_process": executableName,
            "rpath_exit": Int(rpathExit),
            "rpath_output": rpathOutput,
            "insert_dylib_exit": Int(insertExit),
            "insert_output": insertOutput,
            "verified": true,
            "injected": injected,
            "risk_warning": sensitive ? "⚠️ 目标 App 为敏感应用（微信/支付宝/系统/银行类）。已自动选择 Frameworks 内未加密 Mach-O 注入，未修改主二进制；如有异常立即调用 injection.restore 或 rescue.recover_all 恢复。" : nil,
            "hint": "注入目标为 Frameworks 内未加密 Mach-O（对齐 TrollFools 策略），不直接修改主二进制。备份位于 \(backup)，可用 injection.restore 随时恢复。",
            "status": injected ? "injected" : "injection_failed"
        ]
    }

    /// 还原注入（v2.9.89：对齐 TrollFools eject 流程）
    /// 1) 收集有备份的 Mach-O（modified）；2) 移除每个注入资产的加载命令并删文件；
    /// 3) 重签；4) 全部清空后从备份还原并删备份。兼容 TrollFools 注入的 App。
    func disable(bundleId: String) throws -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        guard binaryPath("optool") != nil, binaryPath("ct_bypass") != nil, cpBinary() != nil else {
            throw MCPError.failed("optool / ct_bypass / cp 未内置")
        }

        var modified = collectModifiedMachOs(app)
        var assets = injectedAssets(in: app)

        // 旧格式兼容：有 .bak_macho 但无 .troll-fools.bak 时，主二进制即 modified
        let mainBinary = executablePath(app)
        if FileManager.default.fileExists(atPath: mainBinary + ".bak_macho"),
           !FileManager.default.fileExists(atPath: alternateURL(for: mainBinary)),
           !modified.contains(mainBinary) {
            modified.append(mainBinary)
        }

        guard !modified.isEmpty || !assets.isEmpty else {
            throw MCPError.failed("未发现注入痕迹（无备份、无注入资产）")
        }

        // 杀目标进程
        let executableName = (mainBinary as NSString).lastPathComponent
        _ = spawnRoot("/usr/bin/killall", args: ["killall", "-9", executableName])

        var removedLoads: [String: [String]] = [:]
        var removedAssets: [String] = []

        // 1. 移除每个注入资产的加载命令
        for asset in assets {
            let assetName: String
            if (asset as NSString).pathExtension == "framework" {
                let fwName = (asset as NSString).lastPathComponent
                let exeName = (fwName as NSString).deletingPathExtension
                assetName = "@rpath/\(fwName)/\(exeName)"
            } else {
                assetName = "@rpath/\((asset as NSString).lastPathComponent)"
            }
            var removedFrom: [String] = []
            for target in modified {
                let (c, o) = removeLoadCommand(assetName: assetName, from: target)
                if c == 0 { removedFrom.append(target) }
                else { AuditLog.shared.log("injection.disable.optool", detail: "\(assetName) @ \(target): exit=\(c) \(o)") }
            }
            removedLoads[assetName] = removedFrom
            // 删除资产文件
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: asset, isDirectory: &isDir)
            let (cD, _) = runAsRoot("rm", args: [isDir.boolValue ? "-rf" : "-f", asset])
            if cD == 0 { removedAssets.append(asset) }
        }

        // 2. 重签所有 modified Mach-O
        for target in modified {
            _ = coreTrustBypass(target)
        }

        // 3. 资产清空后从备份还原（对齐 TrollFools ejectAll 的 restoreAlternate 阶段）
        var restored: [String] = []
        if assets.isEmpty || removedAssets.count == assets.count {
            for target in modified {
                if hasAlternate(target) {
                    if (try? restoreAlternate(target)) == true { restored.append(target) }
                }
            }
        }

        let injected = MachOAnalyzer.analyze(mainBinary)?.dylibs.contains(where: { $0.contains("TrollMCPAgent") }) ?? false
        AuditLog.shared.log("injection.disable", detail: "\(bundleId) removed=\(removedAssets.count) restored=\(restored.count)")
        return [
            "action": "remove",
            "bundleId": bundleId,
            "root": true,
            "modified_machos": modified,
            "assets_found": assets,
            "assets_removed": removedAssets,
            "load_commands_removed": removedLoads,
            "restored_from_backup": restored,
            "injected": injected,
            "status": injected ? "still_injected" : "reverted",
            "hint": restored.isEmpty ? "未找到可还原的备份；若 App 仍无法启动，用 rescue.cleanup 清理残留" : "已从备份还原原始二进制"
        ]
    }

    /// 完全移除：还原 + 删除 dylib 文件 + 清理备份
    func remove(bundleId: String) throws -> [String: Any] {
        var r = (try? disable(bundleId: bundleId)) ?? ["action": "remove"]
        if let app = AppCatalog.find(bundleId) {
            // 清理遗留：新格式备份 + 旧格式备份 + 标记文件
            let mainBinary = executablePath(app)
            for backup in [alternateURL(for: mainBinary), mainBinary + ".bak_macho"] {
                if FileManager.default.fileExists(atPath: backup) {
                    let (cD, _) = runAsRoot("rm", args: ["-f", backup])
                    r["backup_removed_\((backup as NSString).lastPathComponent)"] = cD == 0
                }
            }
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

    /// 检查指定 App 是否已注入（兼容新旧备份格式 + 加载命令检测）
    func inspect(_ bundleId: String) -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        let mainBinary = executablePath(app)
        let backup = alternateURL(for: mainBinary)
        let legacyBackup = mainBinary + ".bak_macho"
        let dylibs = MachOAnalyzer.analyze(mainBinary)?.dylibs ?? []
        let injected = isInjected(mainBinary) || dylibs.contains(where: { $0.contains("TrollMCPAgent") })
        let modified = collectModifiedMachOs(app)
        return [
            "app": app.name,
            "bundleId": bundleId,
            "mainBinary": mainBinary,
            "injected": injected,
            "hasBackup": FileManager.default.fileExists(atPath: backup) || FileManager.default.fileExists(atPath: legacyBackup),
            "modified_machos": modified,
            "injected_assets": injectedAssets(in: app),
            "sensitive": Self.isSensitive(bundleId),
            "bundledTools": availableBinaries()
        ]
    }

    /// 列出真正已注入的 App（存在 .troll-fools.bak / .bak_macho 备份即代表曾被注入）
    /// v2.9.58：root 诊断——执行 /usr/bin/id 验证 persona spawn 后子进程真实 uid/gid
    /// 返回 "uid=0(root) gid=0(wheel) ..." 或错误信息
    func diagnoseRoot() -> [String: Any] {
        // v2.9.64：不依赖 /usr/bin/id（部分 iOS 版本无此命令），改用 /bin/sh -c "id"，
        // shell 内置总能执行；同时把 spawn 诊断前缀放进输出，避免空输出误判。
        let shPath = "/bin/sh"
        guard FileManager.default.fileExists(atPath: shPath) else {
            return ["error": "/bin/sh not found", "exit_code": -1, "id_output": "(无shell)", "is_root": false]
        }
        var (code, output) = spawnRoot(shPath, args: ["sh", "-c", "id"])
        if code == -1 || output.isEmpty {
            usleep(100_000)
            (code, output) = spawnRoot(shPath, args: ["sh", "-c", "id"])
        }
        return [
            "exit_code": Int(code),
            "id_output": output.isEmpty ? "(空输出)" : output,
            "is_root": output.contains("uid=0(root)"),
            "note": "persona spawn 后子进程真实身份；若 uid!=0 说明 persona 未生效"
        ]
    }

    func status() -> [String: Any] {
        let apps = AppCatalog.list()
        var injectedApps: [[String: Any]] = []
        for app in apps {
            let mainBinary = executablePath(app)
            if hasAlternate(mainBinary) || !injectedAssets(in: app).isEmpty {
                injectedApps.append([
                    "bundleId": app.bundleId,
                    "name": app.name,
                    "injected": isInjected(mainBinary),
                    "hasBackup": hasAlternate(mainBinary)
                ])
            }
        }
        // v2.9.58：加入 root 诊断
        let rootDiag = diagnoseRoot()
        return [
            "total_apps": apps.count,
            "bundled_tools": availableBinaries(),
            "injected_count": injectedApps.count,
            "injected_apps": injectedApps,
            "root_diagnosis": rootDiag,
            "hint": "要获取具体 App 的 bundle_id + 名称，请调用 injection.list"
        ]
    }
}
