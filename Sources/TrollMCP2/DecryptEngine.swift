import Foundation

// v2.9.128：砸壳引擎（对齐 TrollDecrypt 的 memory dump 算法，全量移植）
// 原理：启动目标 App → task_for_pid 拿端口 → task_info(TASK_DYLD_INFO) 遍历 dyld 镜像
//      找主二进制加载地址 → 读 Mach-O load commands 拿 LC_ENCRYPTION_INFO_64
//      → mach_vm_read_overwrite 从进程内存读"已解密"的加密段 → 重写文件并清 cryptid
//      → 处理 Frameworks → 打包 IPA（纯 Swift Store 模式 zip，零外部依赖）
//
// 失败四分类（CLI 协议）：
//   环境：task_for_pid 失败（缺 get-task-allow / 未开 Entitlements）
//   目标：App 未安装 / 未运行 / 启动失败 / 进程无 dyld 镜像
//   参数：bundle_id 缺失
//   工具：二进制未加密（无需砸壳）/ 解析失败 / 打包失败

// MARK: - Mach 符号声明（与 DeviceProbe 同风格，@_silgen_name 直链）

extension DeviceProbe {
    // 注意：DeviceProbe 是 internal class，extension 成员不能 public（Swift 访问级别规则）
    @_silgen_name("mach_vm_read_overwrite")
    func tm_mach_vm_read_overwrite(_ task: UInt32, _ address: UInt64, _ size: UInt64,
                                   _ data: UInt64, _ outsize: UnsafeMutablePointer<UInt64>) -> Int32

    @_silgen_name("task_info")
    func tm_task_info(_ task: UInt32, _ flavor: Int32,
                      _ info: UnsafeMutableRawPointer,
                      _ count: UnsafeMutablePointer<UInt32>) -> Int32
}

// MARK: - Mach-O / dyld 结构（只定义本项目需要的字段，避免 import 复杂 mach 类型）

private let MH_MAGIC: UInt32 = 0xfeedface
private let MH_MAGIC_64: UInt32 = 0xfeedfacf
private let LC_ENCRYPTION_INFO: UInt32 = 0x21
private let LC_ENCRYPTION_INFO_64: UInt32 = 0x2C
private let TASK_DYLD_INFO: Int32 = 2
private let MAX_DYLD_RETRIES = 300

/// dyld_all_image_infos 只读前 3 个字段（16 字节，布局稳定）
private struct DyldAllImageInfos {
    var version: UInt32
    var infoArrayCount: UInt32
    var infoArray: UInt64
}

/// dyld_image_info（24 字节）
private struct DyldImageInfo {
    var imageLoadAddress: UInt64
    var imageFilePath: UInt64
    var imageFileModDate: UInt64
}
/// encryption_info_command_64（24 字节，32 位版前 20 字节字段一致，cryptid 均在偏移 16）
struct EncryptionInfo {
    var cryptoff: UInt32
    var cryptsize: UInt32
    var cryptid: UInt32
    var loadCommandAddr: UInt64
}

/// 砸壳结果（结构化，供 app.decrypt 直接包装返回）
struct DecryptResult {
    var ok: Bool
    var errorCode: String = ""        // env / target / param / tool
    var errorReason: String = ""
    var nextStep: String = ""
    var pid: Int32 = 0
    var launchErrors: [[String: Any]] = []
    var outputPath: String = ""
    var outputName: String = ""
    var decryptedBinaries: [String] = []
    var cryptInfo: [String: Any] = [:]
}

// MARK: - 砸壳引擎

enum DecryptEngine {

    // MARK: 进程内存读取

    /// 从目标进程内存读取 [address, address+size)
    static func vmRead(task: UInt32, address: UInt64, size: Int) -> Data? {
        guard size > 0, size < 512 << 20 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        var outSize: UInt64 = 0
        let kr = buf.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return DeviceProbe.shared.tm_mach_vm_read_overwrite(
                task, address, UInt64(size), UInt64(UInt(bitPattern: base)), &outSize)
        }
        guard kr == 0, outSize == UInt64(size) else { return nil }
        return Data(buf)
    }

    /// 从目标进程内存读 C 字符串（遇 NUL 截断）
    static func vmReadString(task: UInt32, address: UInt64, maxLen: Int = 4096) -> String? {
        guard let d = vmRead(task: task, address: address, size: maxLen) else { return nil }
        var bytes = [UInt8](d)
        if let nul = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<nul]) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func loadU32(_ d: Data, _ off: Int) -> UInt32 {
        guard off + 4 <= d.count else { return 0 }
        return UInt32(d[d.startIndex + off]) | (UInt32(d[d.startIndex + off + 1]) << 8)
            | (UInt32(d[d.startIndex + off + 2]) << 16) | (UInt32(d[d.startIndex + off + 3]) << 24)
    }

    private static func loadU64(_ d: Data, _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[d.startIndex + off + i]) << (8 * UInt64(i)) }
        return v
    }

    // MARK: 启动 App（复用 app.start 三层降级，返回 pid；失败返回错误明细）

    static func launchApp(bundleId: String, waitSeconds: Int = 3) -> (pid: Int32, errors: [[String: Any]]) {
        func find() -> Int32 { findPid(by: bundleId) }
        var errors: [[String: Any]] = []

        // 方法 0（v2.9.185）：LSApplicationWorkspace 私有 API 拉起——TrollStore 环境可用，
        // 不依赖 shell/root（open -b 与 direct_exec 在无 shell 环境全部 spawnRoot failed，真机实测）。
        if let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
           ws.responds(to: NSSelectorFromString("openApplicationWithBundleID:")) {
            _ = ws.perform(NSSelectorFromString("openApplicationWithBundleID:"), with: bundleId)
            Thread.sleep(forTimeInterval: TimeInterval(waitSeconds))
            var pid0 = find()
            if pid0 > 0 { return (pid0, errors) }
            errors.append(["step": "ls_workspace_open", "exit": 0, "stderr": "openApplicationWithBundleID 未拉起（系统限制或 App 不可启动）"])
        }

        // 方法 1：open -b
        let (c1, o1) = InjectionManager.shared.spawnRoot("/usr/bin/open", args: ["-b", bundleId])
        Thread.sleep(forTimeInterval: TimeInterval(waitSeconds))
        var pid = find()
        if pid > 0 { return (pid, errors) }
        errors.append(["step": "open -b", "exit": Int(c1), "stderr": String(o1.prefix(300))])

        // 方法 2：注册表路径直接 exec 主二进制
        if let app = AppCatalog.find(bundleId) {
            let plist = NSDictionary(contentsOfFile: app.path + "/Info.plist")
            let exec = (plist?["CFBundleExecutable"] as? String) ?? ""
            if !app.path.isEmpty, !exec.isEmpty {
                let bin = app.path + "/" + exec
                if FileManager.default.fileExists(atPath: bin) {
                    let (c2, o2) = InjectionManager.shared.spawnRoot(bin, args: [])
                    Thread.sleep(forTimeInterval: TimeInterval(waitSeconds))
                    pid = find()
                    if pid > 0 { return (pid, errors) }
                    errors.append(["step": "direct_exec", "exit": Int(c2), "stderr": String(o2.prefix(300))])
                }
            }
        }
        return (0, errors)
    }

    // MARK: 查找主二进制加载地址（task_info → dyld infoArray 匹配路径）

    /// 在目标进程的 dyld 镜像表里找 imageFilePath == 目标二进制路径的加载地址
    static func findImageLoadAddress(task: UInt32, pid: Int32, binaryPath: String) -> UInt64? {
        return findImageLoadAddressDiag(task: task, pid: pid, binaryPath: binaryPath).0
    }

    /// v2.9.188：带诊断版——返回 (加载地址, 最后失败原因)，失败原因进 app.decrypt 报错，
    /// 不再笼统报"镜像表未找到"
    static func findImageLoadAddressDiag(task: UInt32, pid: Int32, binaryPath: String) -> (UInt64?, String?) {
        var lastDiag: String? = nil
        for _ in 0..<MAX_DYLD_RETRIES {
            var dyldInfo = TaskDyldInfoBuf()
            var count: UInt32 = UInt32(MemoryLayout<TaskDyldInfoBuf>.size / 4)
            let kr = withUnsafeMutableBytes(of: &dyldInfo) { raw -> Int32 in
                DeviceProbe.shared.tm_task_info(task, TASK_DYLD_INFO, raw.baseAddress!, &count)
            }
            guard kr == 0, dyldInfo.all_image_info_addr != 0 else {
                lastDiag = (kr != 0) ? "task_info kr=\(kr)" : "all_image_info_addr=0"
                Thread.sleep(forTimeInterval: 0.01); continue
            }
            guard let infosData = vmRead(task: task, address: dyldInfo.all_image_info_addr,
                                         size: MemoryLayout<DyldAllImageInfos>.size) else {
                lastDiag = "vmRead dyld_all_image_infos 失败 addr=\(dyldInfo.all_image_info_addr)"
                Thread.sleep(forTimeInterval: 0.01); continue
            }
            let infos = DyldAllImageInfos(version: loadU32(infosData, 0),
                                          infoArrayCount: loadU32(infosData, 4),
                                          infoArray: loadU64(infosData, 8))
            guard infos.infoArrayCount > 0, infos.infoArrayCount < 4096, infos.infoArray != 0 else {
                lastDiag = "infoArrayCount=\(infos.infoArrayCount) infoArray=0x\(String(infos.infoArray, radix: 16))"
                Thread.sleep(forTimeInterval: 0.01); continue
            }
            let itemSize = MemoryLayout<DyldImageInfo>.size
            let arrayBytes = Int(infos.infoArrayCount) * itemSize
            guard let arrData = vmRead(task: task, address: infos.infoArray, size: arrayBytes) else {
                lastDiag = "vmRead infoArray 失败 count=\(infos.infoArrayCount)"
                Thread.sleep(forTimeInterval: 0.01); continue
            }
            let want = canonicalPath(binaryPath)
            for j in 0..<Int(infos.infoArrayCount) {
                let off = j * itemSize
                let loadAddr = loadU64(arrData, off)
                let filePathPtr = loadU64(arrData, off + 8)
                guard filePathPtr != 0,
                      let path = vmReadString(task: task, address: filePathPtr, maxLen: 4096) else { continue }
                if canonicalPath(path) == want {
                    return (loadAddr, nil)
                }
            }
            lastDiag = "表项\(infos.infoArrayCount)条无路径匹配(目标 \(want))"
            Thread.sleep(forTimeInterval: 0.01)
        }
        return (nil, lastDiag)
    }

    /// 路径规范化：去掉 /private 前缀差异（TrollDecrypt 同款处理）
    private static func canonicalPath(_ p: String) -> String {
        if p.hasPrefix("/private/") { return String(p.dropFirst("/private".count)) }
        return p
    }

    // MARK: 读取加密信息（LC_ENCRYPTION_INFO[_64]）

    static func readEncryptionInfo(task: UInt32, loadAddress: UInt64) -> EncryptionInfo? {
        guard let headerData = vmRead(task: task, address: loadAddress, size: 32) else { return nil }
        let magic = loadU32(headerData, 0)
        let ncmds = loadU32(headerData, 16)
        var offset: Int
        switch magic {
        case MH_MAGIC_64: offset = 32
        case MH_MAGIC: offset = 28
        default: return nil
        }
        guard ncmds > 0, ncmds < 4096 else { return nil }
        var addr = loadAddress + UInt64(offset)
        for _ in 0..<ncmds {
            guard let lc = vmRead(task: task, address: addr, size: 8) else { return nil }
            let cmd = loadU32(lc, 0)
            let cmdsize = loadU32(lc, 4)
            guard cmdsize >= 8, cmdsize <= 1 << 16 else { return nil }
            if cmd == LC_ENCRYPTION_INFO || cmd == LC_ENCRYPTION_INFO_64 {
                guard let enc = vmRead(task: task, address: addr, size: 24) else { return nil }
                return EncryptionInfo(cryptoff: loadU32(enc, 8),
                                      cryptsize: loadU32(enc, 12),
                                      cryptid: loadU32(enc, 16),
                                      loadCommandAddr: addr)
            }
            addr += UInt64(cmdsize)
        }
        // 没有加密命令 = 未加密（合法）
        return EncryptionInfo(cryptoff: 0, cryptsize: 0, cryptid: 0, loadCommandAddr: 0)
    }

    // MARK: 重建解密镜像

    /// 读源文件 [0,cryptoff) + 从进程内存读解密段 + 读源文件尾部 + 清 cryptid
    static func rebuildDecryptedImage(sourcePath: String, task: UInt32, loadAddress: UInt64,
                                      enc: EncryptionInfo, outputPath: String) -> Bool {
        guard let src = FileHandle(forReadingAtPath: sourcePath) else { return false }
        defer { try? src.close() }
        let fileSize = (try? src.seekToEnd()) ?? 0
        try? src.seek(toOffset: 0)
        let cryptEnd = UInt64(enc.cryptoff) + UInt64(enc.cryptsize)
        if cryptEnd > fileSize { return false }

        FileManager.default.createFile(atPath: outputPath, contents: nil)
        guard let dst = FileHandle(forWritingAtPath: outputPath) else { return false }
        defer { try? dst.close() }

        // 1) 头部 [0, cryptoff)
        if enc.cryptoff > 0 {
            try? src.seek(toOffset: 0)
            let d = src.readData(ofLength: Int(enc.cryptoff))
            guard d.count == Int(enc.cryptoff) else { return false }
            dst.write(d)
        }
        // 2) 解密段：从进程内存读（运行中的镜像已解密）
        if enc.cryptsize > 0 {
            guard let dec = vmRead(task: task, address: loadAddress + UInt64(enc.cryptoff),
                                   size: Int(enc.cryptsize)) else { return false }
            guard dec.count == Int(enc.cryptsize) else { return false }
            dst.write(dec)
        }
        // 3) 尾部 [cryptEnd, EOF)
        if fileSize > cryptEnd {
            try? src.seek(toOffset: cryptEnd)
            var remaining = fileSize - cryptEnd
            while remaining > 0 {
                let chunk = min(remaining, UInt64(1 << 20))
                let d = src.readData(ofLength: Int(chunk))
                guard d.count == Int(chunk) else { return false }
                dst.write(d)
                remaining -= chunk
            }
        }
        // 4) 清 cryptid（cryptid 在 encryption_info_command 偏移 16）
        if enc.loadCommandAddr > 0 {
            let cmdOff = enc.loadCommandAddr - loadAddress
            try? dst.seek(toOffset: cmdOff + 16)
            dst.write(Data([0, 0, 0, 0]))
        }
        try? dst.synchronize()
        return true
    }

    // MARK: 处理单个二进制

    /// 解密单个二进制；cryptid==0 表示无需砸壳（返回 .notEncrypted）
    enum SingleResult { case ok, notEncrypted, failed(Int32, String) }

    static func decryptBinary(sourcePath: String, task: UInt32, pid: Int32, outputPath: String) -> SingleResult {
        let (loadAddr, diag) = findImageLoadAddressDiag(task: task, pid: pid, binaryPath: sourcePath)
        guard let loadAddr else {
            return .failed(0, "dyld 镜像表未找到 \(sourcePath)：\(diag ?? "未知原因")")
        }
        guard let enc = readEncryptionInfo(task: task, loadAddress: loadAddr) else {
            return .failed(0, "读取 Mach-O load commands 失败（可能解析异常）")
        }
        if enc.cryptid == 0 {
            return .notEncrypted
        }
        guard rebuildDecryptedImage(sourcePath: sourcePath, task: task, loadAddress: loadAddr,
                                    enc: enc, outputPath: outputPath) else {
            return .failed(0, "重建解密镜像失败（内存读取或文件写入错误）")
        }
        return .ok
    }

    // MARK: 主流程（供 app.decrypt 调用）

    static func decryptApp(bundleId: String, outputName: String?) -> DecryptResult {
        // —— 参数检查 ——
        guard !bundleId.isEmpty else {
            return DecryptResult(ok: false, errorCode: "param", errorReason: "bundle_id 为空",
                                 nextStep: "传入目标 App 的 Bundle ID")
        }
        guard let app = AppCatalog.list().first(where: { $0.bundleId == bundleId }) else {
            return DecryptResult(ok: false, errorCode: "target", errorReason: "未找到 App: \(bundleId)",
                                 nextStep: "用 injection.list 搜索目标 App 的 bundle_id")
        }

        // —— 拿进程：已在运行直接用，否则启动 ——
        var pid = findPid(by: bundleId)
        var launchErrors: [[String: Any]] = []
        if pid <= 0 {
            let r = launchApp(bundleId: bundleId)
            pid = r.pid
            launchErrors = r.errors
        }
        guard pid > 0 else {
            return DecryptResult(ok: false, errorCode: "target",
                                 errorReason: "目标 App 未运行且启动失败（open -b / direct_exec 均无效）",
                                 nextStep: "手动打开目标 App 后再执行砸壳；或在 TrollStore 里确认该 App 可正常启动",
                                 pid: 0, launchErrors: launchErrors)
        }

        // —— v2.9.198：注入式优先 ——
        // 实测 task_for_pid 虽成功（kr=0）但 task_info(TASK_DYLD_INFO) 恒 kr=4（跨进程读镜像表死路，
        // v2.9.184 已证），原降级条件只认 task_for_pid 失败 → 永远走不进注入式。
        // 现改为：ControlAgent(4789) 在线 → 直接注入式（进程内自解密）；否则回退跨进程。
        if (ControlAgentTools.shared.status(retries: 2)["connected"] as? Bool) == true {
            let viaCA = decryptViaControlAgent(app: app, bundleId: bundleId, pid: pid, launchErrors: launchErrors)
            if viaCA.ok { return viaCA }
            return DecryptResult(ok: false, errorCode: "env",
                                 errorReason: "注入式砸壳不可用: \(viaCA.errorReason)",
                                 nextStep: viaCA.nextStep, pid: pid, launchErrors: launchErrors)
        }

        // —— task_for_pid ——
        var task: UInt32 = 0
        let kr = DeviceProbe.shared.tm_task_for_pid(DeviceProbe.shared.tm_mach_task_self(), pid, &task)
        guard kr == 0, task != 0 else {
            // v2.9.186：TrollStore 无 task-for-pid-allow（实测 task_for_pid false），
            // 自动降级「注入式砸壳」：注入 ControlAgent → 目标进程内自解密（绕开跨进程 task_for_pid）
            let viaCA = decryptViaControlAgent(app: app, bundleId: bundleId, pid: pid, launchErrors: launchErrors)
            if viaCA.ok { return viaCA }
            return DecryptResult(ok: false, errorCode: "env",
                                 errorReason: "task_for_pid 失败（kern_return=\(Int(kr))）且注入式砸壳降级不可用: \(viaCA.errorReason)",
                                 nextStep: viaCA.nextStep, pid: pid, launchErrors: launchErrors)
        }
        defer { DeviceProbe.shared.tm_mach_port_deallocate(DeviceProbe.shared.tm_mach_task_self(), task) }

        // —— 准备输出目录 ——
        let workspace = NSHomeDirectory().appending("/Documents/Workspace/decrypted")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let plist = NSDictionary(contentsOfFile: app.path + "/Info.plist")
        let execName = (plist?["CFBundleExecutable"] as? String) ?? "App"
        let mainBinary = app.path + "/" + execName
        let safeBase = (outputName ?? app.name)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let version = (plist?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let workingRoot = workspace + "/\(safeBase)_work"
        try? FileManager.default.removeItem(atPath: workingRoot)
        let payloadDir = workingRoot + "/Payload"
        let destApp = payloadDir + "/" + (app.path as NSString).lastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: payloadDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: app.path, toPath: destApp)
        } catch {
            return DecryptResult(ok: false, errorCode: "tool",
                                 errorReason: "复制 App Bundle 失败: \(error.localizedDescription)",
                                 nextStep: "确认 device_probe 的 App 容器任意读写为 ✔；空间不足则清理工作区",
                                 pid: pid, launchErrors: launchErrors)
        }

        var decrypted: [String] = []
        var cryptInfo: [String: Any] = [:]

        // —— 解密主二进制 ——
        let destMain = destApp + "/" + execName
        switch decryptBinary(sourcePath: mainBinary, task: task, pid: pid, outputPath: destMain) {
        case .ok:
            decrypted.append(mainBinary)
            cryptInfo["main"] = ["cryptid": 0, "decrypted": true]
        case .notEncrypted:
            cryptInfo["main"] = ["cryptid": 0, "decrypted": false, "reason": "主二进制未加密（已砸壳或侧载）"]
        case .failed(let k, let msg):
            cryptInfo["main"] = ["cryptid": -1, "decrypted": false, "reason": msg, "kern_return": k]
        }

        // —— 解密 Frameworks（TrollDecrypt 同款：遍历 .framework 内同名二进制）——
        let frameworksPath = app.path + "/Frameworks"
        if let items = try? FileManager.default.contentsOfDirectory(atPath: frameworksPath) {
            for item in items where item.hasSuffix(".framework") {
                let fwBinary = frameworksPath + "/" + item + "/" + (item as NSString).deletingPathExtension
                let destFw = destApp + "/Frameworks/" + item + "/" + (item as NSString).deletingPathExtension
                guard FileManager.default.fileExists(atPath: fwBinary),
                      FileManager.default.fileExists(atPath: destFw) else { continue }
                // framework 镜像也要在 dyld 表里（框架加载后才有）
                switch decryptBinary(sourcePath: fwBinary, task: task, pid: pid, outputPath: destFw) {
                case .ok:
                    decrypted.append(fwBinary)
                    cryptInfo[item] = ["cryptid": 0, "decrypted": true]
                case .notEncrypted:
                    cryptInfo[item] = ["cryptid": 0, "decrypted": false, "reason": "未加密"]
                case .failed(let k, let msg):
                    cryptInfo[item] = ["cryptid": -1, "decrypted": false, "reason": msg, "kern_return": k]
                }
            }
        }

        // —— 打包 IPA（纯 Swift Store 模式）——
        let ipaName = "\(bundleId)_\(version)_decrypted.ipa"
        let ipaPath = workspace + "/" + ipaName
        try? FileManager.default.removeItem(atPath: ipaPath)
        guard ZipStorer.createZip(at: ipaPath, fromDirectory: workingRoot) else {
            return DecryptResult(ok: false, errorCode: "tool",
                                 errorReason: "打包 IPA 失败（zip 写入错误）",
                                 nextStep: "工作区临时文件保留在 \(workingRoot)，可手动打包",
                                 pid: pid, launchErrors: launchErrors)
        }
        try? FileManager.default.removeItem(atPath: workingRoot)

        // —— 杀掉砸壳时启动的进程（仅当是我们启动的）——
        if !launchErrors.isEmpty {
            _ = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(pid)"])
        }

        return DecryptResult(ok: true, pid: pid, launchErrors: launchErrors,
                             outputPath: ipaPath, outputName: ipaName,
                             decryptedBinaries: decrypted, cryptInfo: cryptInfo)
    }

    // MARK: - v2.9.186 注入式砸壳（ControlAgent 进程内自解密，绕开 task_for_pid）
    // 流程：注入 ControlAgent.dylib → 重启目标 App → 4789 在线 → /decrypt 进程内遍历
    // dyld 镜像（dyld 已把加密页解密到内存，从内存读已解密段写副本）→ 从目标 App 容器
    // 取解密副本覆盖 Payload 对应二进制 → 打包 IPA。

    private static func decryptViaControlAgent(app: AppCatalog.AppEntry, bundleId: String,
                                               pid: pid_t, launchErrors: [[String: Any]]) -> DecryptResult {
        // 0. 准备输出目录 + 复制 bundle（同主流程）
        let workspace = NSHomeDirectory().appending("/Documents/Workspace/decrypted")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let plist = NSDictionary(contentsOfFile: app.path + "/Info.plist")
        let execName = (plist?["CFBundleExecutable"] as? String) ?? "App"
        let version = (plist?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let workingRoot = workspace + "/\(bundleId)_\(version)_work"
        try? FileManager.default.removeItem(atPath: workingRoot)
        let payloadDir = workingRoot + "/Payload"
        let destApp = payloadDir + "/" + (app.path as NSString).lastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: payloadDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: app.path, toPath: destApp)
        } catch {
            return DecryptResult(ok: false, errorCode: "tool",
                                 errorReason: "复制 App Bundle 失败: \(error.localizedDescription)",
                                 nextStep: "确认 device_probe 的 App 容器任意读写为 ✔；空间不足则清理工作区",
                                 pid: pid, launchErrors: launchErrors)
        }

        // 1. 注入 ControlAgent（4789 已在线则跳过）
        let tools = ControlAgentTools.shared
        var connected = (tools.status(retries: 1)["connected"] as? Bool) ?? false
        if !connected {
            let inj = tools.inject(bundleId: bundleId)
            if let err = inj["error"] as? String {
                return DecryptResult(ok: false, errorCode: "tool",
                                     errorReason: "注入 ControlAgent 失败: \(err)",
                                     nextStep: "手动用 control.inject 注入后再试",
                                     pid: pid, launchErrors: launchErrors)
            }
            _ = launchApp(bundleId: bundleId) // 重启目标 App 加载 dylib
            connected = (tools.status(retries: 15)["connected"] as? Bool) ?? false
        }
        guard connected else {
            return DecryptResult(ok: false, errorCode: "env",
                                 errorReason: "注入后 ControlAgent(4789) 未就绪，注入式砸壳不可用",
                                 nextStep: "确认目标 App 能正常启动（可先手动打开一次）；注入后需重启目标 App",
                                 pid: pid, launchErrors: launchErrors)
        }

        // 2. 调 /decrypt（进程内自解密）
        let dec = tools.decrypt()
        guard (dec["connected"] as? Bool) == true else {
            return DecryptResult(ok: false, errorCode: "tool",
                                 errorReason: "/decrypt 无响应: \(dec["error"] ?? "")",
                                 nextStep: "检查 ControlAgent 版本（需 ≥ v2.9.186 的 /decrypt 端点）",
                                 pid: pid, launchErrors: launchErrors)
        }
        let results = (dec["results"] as? [[String: Any]]) ?? []
        var decrypted: [String] = []
        var cryptInfo: [String: Any] = [:]
        for r in results {
            guard let out = r["output"] as? String, !out.isEmpty,
                  (r["decrypted"] as? Bool) == true else { continue }
            let name = (out as NSString).lastPathComponent
            if name == execName {
                // 主二进制
                try? FileManager.default.removeItem(atPath: destApp + "/" + execName)
                try? FileManager.default.copyItem(atPath: out, toPath: destApp + "/" + execName)
                cryptInfo["main"] = ["cryptid": 0, "decrypted": true, "method": "controlagent"]
                decrypted.append(out)
            } else {
                // Frameworks：按二进制名匹配 .framework 目录
                let fwDir = destApp + "/Frameworks"
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: fwDir) {
                    for fw in entries where fw.hasSuffix(".framework") {
                        if (fw as NSString).deletingPathExtension == name {
                            let dest = fwDir + "/" + fw + "/" + name
                            try? FileManager.default.removeItem(atPath: dest)
                            try? FileManager.default.copyItem(atPath: out, toPath: dest)
                            cryptInfo[fw] = ["cryptid": 0, "decrypted": true, "method": "controlagent"]
                            decrypted.append(out)
                            break
                        }
                    }
                }
            }
        }

        // 3. 打包 IPA
        let ipaName = "\(bundleId)_\(version)_decrypted.ipa"
        let ipaPath = workspace + "/" + ipaName
        try? FileManager.default.removeItem(atPath: ipaPath)
        guard ZipStorer.createZip(at: ipaPath, fromDirectory: workingRoot) else {
            return DecryptResult(ok: false, errorCode: "tool",
                                 errorReason: "打包 IPA 失败（zip 写入错误）",
                                 nextStep: "工作区临时文件保留在 \(workingRoot)，可手动打包",
                                 pid: pid, launchErrors: launchErrors)
        }
        try? FileManager.default.removeItem(atPath: workingRoot)

        return DecryptResult(ok: true, pid: pid, launchErrors: launchErrors,
                             outputPath: ipaPath, outputName: ipaName,
                             decryptedBinaries: decrypted, cryptInfo: cryptInfo)
    }
}

// MARK: - task_dyld_info 缓冲（20 字节：addr + size + format）

private struct TaskDyldInfoBuf {
    var all_image_info_addr: UInt64 = 0
    var all_image_info_size: UInt64 = 0
    var all_image_info_format: Int32 = 0
}

// MARK: - 纯 Swift Zip 打包器（Store 方法，零外部依赖）

enum ZipStorer {

    static func createZip(at zipPath: String, fromDirectory dirPath: String) -> Bool {
        var files: [(rel: String, abs: String)] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dirPath) else { return false }
        for case let rel as String in enumerator {
            let abs = dirPath + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs, isDirectory: &isDir), !isDir.boolValue else { continue }
            files.append((rel, abs))
        }
        guard !files.isEmpty, fm.createFile(atPath: zipPath, contents: nil) else { return false }
        guard let out = FileHandle(forWritingAtPath: zipPath) else { return false }
        defer { try? out.close() }

        var centralDir = Data()
        var offset: UInt64 = 0

        for f in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: f.abs)) else { return false }
            let nameData = Data(f.rel.utf8)
            let crc = crc32(data)
            let size = UInt32(data.count)

            // Local File Header
            var lfh = Data()
            appendU32(&lfh, 0x04034b50)
            appendU16(&lfh, 20)          // version needed
            appendU16(&lfh, 0x0800)      // flags: UTF-8
            appendU16(&lfh, 0)           // method: store
            appendU16(&lfh, 0)           // mod time
            appendU16(&lfh, 0)           // mod date
            appendU32(&lfh, crc)
            appendU32(&lfh, size)
            appendU32(&lfh, size)
            appendU16(&lfh, UInt16(nameData.count))
            appendU16(&lfh, 0)           // extra len
            lfh.append(nameData)
            out.write(lfh)
            out.write(data)
            offset += UInt64(lfh.count + data.count)

            // Central Directory Entry
            var cd = Data()
            appendU32(&cd, 0x02014b50)
            appendU16(&cd, 20)           // version made by
            appendU16(&cd, 20)           // version needed
            appendU16(&cd, 0x0800)
            appendU16(&cd, 0)            // method
            appendU16(&cd, 0)            // time
            appendU16(&cd, 0)            // date
            appendU32(&cd, crc)
            appendU32(&cd, size)
            appendU32(&cd, size)
            appendU16(&cd, UInt16(nameData.count))
            appendU16(&cd, 0)            // extra
            appendU16(&cd, 0)            // comment
            appendU16(&cd, 0)            // disk start
            appendU16(&cd, 0)            // internal attrs
            appendU32(&cd, 0)            // external attrs
            appendU32(&cd, UInt32(offset - UInt64(lfh.count + data.count)))  // local header offset
            cd.append(nameData)
            centralDir.append(cd)
        }

        // End of Central Directory
        var eocd = Data()
        appendU32(&eocd, 0x06054b50)
        appendU16(&eocd, 0)
        appendU16(&eocd, 0)
        appendU16(&eocd, UInt16(files.count))
        appendU16(&eocd, UInt16(files.count))
        appendU32(&eocd, UInt32(centralDir.count))
        appendU32(&eocd, UInt32(offset))
        appendU16(&eocd, 0)

        out.write(centralDir)
        out.write(eocd)
        try? out.synchronize()
        return true
    }

    // MARK: CRC32（查表法）

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func appendU16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
    }

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
    }
}

// findPid 使用 ProcessTools.swift 全局版（internal，避免重名）
