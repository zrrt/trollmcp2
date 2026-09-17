import Foundation
import Compression
import zlib

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
// ★v2.9.223 终极根因★: iOS 16(XNU-7195)官方头文件 osfmk/mach/task_info.h 实锤:
//   TASK_DYLD_INFO = 17 !!! (macOS 才是 2; 25 也不对)
//   struct task_dyld_info { mach_vm_address_t all_image_info_addr(8); mach_vm_size_t all_image_info_size(8); integer_t all_image_info_format(4); } = 20字节 = TASK_DYLD_INFO_COUNT=5
// 错误链: flavor=2(macOS值,iOS上是TASK_EVENTS_INFO事件计数) → 25(猜错) → 17(XNU实锤)
private let TASK_DYLD_INFO: Int32 = 17
private let MAX_DYLD_RETRIES = 3000 // v2.9.221: 30秒重试窗口(dyld镜像表可能晚初始化,实测3秒内恒垃圾值)

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
    var diag: [String: Any] = [:]   // v2.9.209 诊断字段（task_basic_info 等）
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
            return MachRaw.vmReadOverwrite(
                task: task, address: address, size: UInt64(size),
                data: UInt64(UInt(bitPattern: base)), outsize: &outSize)
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
            // ★v2.9.222 根因★：iOS 的 TASK_DYLD_INFO=25（macOS 才是 2）！
            // flavor=2 在 iOS 是 TASK_EVENTS_INFO（事件计数，8×natural_t，count=8）
            // → 之前所有版本 dump 全是"事件计数"（0x1195恒定=reactivations=4501），dyld 地址从没读到过。
            // count 扫描 6/8/10/12/16 找 kr=0，再验证 off0 是否为有效用户地址。
            var dyldBuf = [UInt8](repeating: 0, count: 64)
            var kr: Int32 = -99
            var chosenCount: UInt32 = 0
            for c: UInt32 in [5, 6, 8, 10, 12, 16] { // XNU: TASK_DYLD_INFO_COUNT=5(20字节)
                var tmp = [UInt8](repeating: 0, count: 64)
                var cnt = c
                let k = tmp.withUnsafeMutableBytes { raw -> Int32 in
                    MachRaw.taskInfo(task: task, flavor: TASK_DYLD_INFO, info: raw.baseAddress!, count: &cnt)
                }
                if k == 0 && cnt >= 4 { dyldBuf = tmp; kr = 0; chosenCount = c; break } // v2.9.224: count=5(XNU正解)此前被cnt>=8过滤
            }
            let dyldInfoAddr = loadU64(Data(dyldBuf), 0)
            var regionDiagStr = ""
            if kr == 0 {
                let n = min(Int(chosenCount) * 4, dyldBuf.count)
                regionDiagStr = "cnt=\(chosenCount) buf=0x" + dyldBuf[0..<n].map { String(format: "%02x", $0) }.joined()
                for off in stride(from: 0, to: n, by: 8) {
                    var probe = loadU64(Data(dyldBuf), off)
                    guard probe != 0 else { continue }
                    var regionSize: UInt64 = 0
                    var regionInfo = [UInt8](repeating: 0, count: 160)
                    var regionCnt: UInt32 = 16
                    var objName: UInt32 = 0
                    let krRegion = regionInfo.withUnsafeMutableBytes { raw -> Int32 in
                        MachRaw.vmRegion(task: task, address: &probe, size: &regionSize,
                                         flavor: 9, info: raw.baseAddress!,
                                         infoCount: &regionCnt, objectName: &objName)
                    }
                    regionDiagStr += " off\(off)=0x\(String(probe, radix: 16)) r=\(krRegion)"
                }
            }
            guard kr == 0, dyldInfoAddr != 0 else {
                lastDiag = (kr != 0) ? "task_info kr=\(kr)" : "all_image_info_addr=0"
                Thread.sleep(forTimeInterval: 0.01); continue
            }
            guard let infosData = vmRead(task: task, address: dyldInfoAddr,
                                         size: MemoryLayout<DyldAllImageInfos>.size) else {
                lastDiag = "vmRead dyld_all_image_infos 失败 addr=0x\(String(dyldInfoAddr, radix: 16)) \(regionDiagStr)"
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
                // v2.9.225 诊断: dump 表里含 Frameworks 的路径,确认是未加载还是路径形式差异
                var fwPaths = [String]()
                for j in 0..<min(Int(infos.infoArrayCount), 947) {
                    let off = j * itemSize
                    let fp = loadU64(arrData, off + 8)
                    if fp != 0, let pth = vmReadString(task: task, address: fp, maxLen: 2048),
                       pth.contains("Frameworks") { fwPaths.append(pth) }
                }
                if let d = lastDiag {
                    var nd = d + " fw["
                    for fp in fwPaths.prefix(6) { nd += fp + " | " }
                    lastDiag = nd + "]"
                }
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

        // —— 拿进程：v2.9.218 open -b 前台启动优先 ——
        // 实测结论（v2.9.214-217）：launchd SubmitAndStart 启动的进程虽然 pid 存活，
        // 但 dyld 镜像表一直无效（region_kr=1 KERN_INVALID_ADDRESS，等 3s/重试 300 次都无效），
        // 说明该 job 进程 dyld 根本没完成初始化（不是时序问题，是启动方式问题）。
        // 改 open -b 前台激活：完整 App 进程 dyld 必然初始化，count=8（v2.9.213 修复）可读到镜像表。
        // （注：v2.9.184 记录"open -b 进程 task_info kr=4"是 24 字节 count=6 的错误结论，已被 count=8 推翻）
        var pid: Int32 = 0
        var launchErrors: [[String: Any]] = []
        let r0 = launchApp(bundleId: bundleId)
        pid = r0.pid
        launchErrors = r0.errors
        if pid <= 0 {
            // launchd 兜底（TrollDecrypt 同款机制）
            let plist0 = NSDictionary(contentsOfFile: app.path + "/Info.plist")
            let execName0 = (plist0?["CFBundleExecutable"] as? String) ?? "App"
            let mainBinary0 = app.path + "/" + execName0
            if FileManager.default.fileExists(atPath: mainBinary0) {
                let label = String(format: "UIKitApplication:%@[%06x]", bundleId, arc4random() & 0xffffff)
                let lr = LaunchdLauncher.launch(bundleId: bundleId, executablePath: mainBinary0, label: label)
                if lr.pid > 0 { pid = lr.pid }
                launchErrors.append(["step": "launchd_submit_fallback", "kern_return": Int(lr.kr)])
            }
        }
        guard pid > 0 else {
            return DecryptResult(ok: false, errorCode: "target",
                                 errorReason: "目标 App 启动失败（open -b + launchd SubmitAndStart 均无效）",
                                 nextStep: "手动打开目标 App 后再执行砸壳；或在 TrollStore 里确认该 App 可正常启动",
                                 pid: 0, launchErrors: launchErrors)
        }
        // v2.9.217：launchd 复制 bundle 的初始化窗口；open -b 前台启动也等 5 秒让 dyld 完整初始化。
        Thread.sleep(forTimeInterval: 5.0)

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

        // —— v2.9.209 诊断：TASK_BASIC_INFO 对照 ——
        // 用途：区分"task_info 调用本身挂"（ABI/权限）vs"TASK_DYLD_INFO 特有被拒"（进程类型）。
        // TrollDecrypt 同环境成功 → 我们 task_info(TASK_DYLD_INFO) 恒 kr=4 必有实现差异。
        // krBasic==0 说明 task_info 调用链通，问题在 TASK_DYLD_INFO 的进程/权限；
        // krBasic==4 说明整个 task_info 调用都挂（调用约定/端口值）。
        var basicDiag: [String: Any] = ["flavor": "TASK_BASIC_INFO(4)"]
        do {
            var basicBuf = [UInt8](repeating: 0, count: 128)
            var basicCount: UInt32 = 32 // TASK_BASIC_INFO_COUNT 上限
            let krBasic = basicBuf.withUnsafeMutableBytes { raw -> Int32 in
                MachRaw.taskInfo(task: task, flavor: 4, info: raw.baseAddress!, count: &basicCount)
            }
            basicDiag["kr"] = Int(krBasic)
            basicDiag["count_after"] = Int(basicCount)
        }
        // v2.9.212：TASK_DYLD_INFO 多参数变体全测（count=4/5/6/8 + 64B 缓冲）
        // 定位：TASK_BASIC_INFO kr=0（调用链通）但 TASK_DYLD_INFO 恒 kr=4 → flavor 特有。
        // 逐个 count 试，若某组合 kr=0 → 找到内核接受参数；全 kr=4 → 进程类型被拒，转注入式/前台激活。
        var dyldDiag: [String: Any] = ["flavor": "TASK_DYLD_INFO(2)"]
        for c in [4, 5, 6, 8] {
            var dyldBuf = [UInt8](repeating: 0, count: 64)
            var dyldCnt: UInt32 = UInt32(c)
            let krD = dyldBuf.withUnsafeMutableBytes { raw -> Int32 in
                MachRaw.taskInfo(task: task, flavor: 2, info: raw.baseAddress!, count: &dyldCnt)
            }
            dyldDiag["count_\(c)"] = ["kr": Int(krD), "count_after": Int(dyldCnt)]
        }
        basicDiag["task_dyld_variants"] = dyldDiag

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
                             decryptedBinaries: decrypted, cryptInfo: cryptInfo,
                             diag: ["task_basic_info": basicDiag])
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
            // v2.9.199：未加密（cryptid=0/无加密段）也记入 cryptInfo，不再静默过滤成"假完成"
            if let out = (r["output"] as? String) ?? (r["path"] as? String), !out.isEmpty,
               (r["decrypted"] as? Bool) != true,
               let cryptid = r["cryptid"] as? Int, cryptid == 0 {
                let name = (out as NSString).lastPathComponent
                let note = (r["note"] as? String) ?? "未加密"
                cryptInfo[name == execName ? "main" : name] = ["cryptid": 0, "decrypted": false, "reason": note, "method": "controlagent"]
                continue
            }
            guard let out = (r["output"] as? String) ?? (r["path"] as? String), !out.isEmpty,
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

// MARK: - task_dyld_info 缓冲（v2.9.205 修复：必须 24 字节！）
// task_dyld_info_data_t = {mach_vm_address_t(8), mach_vm_size_t(8), boolean_t(4)} + 4 字节尾部 padding = 24
// TASK_DYLD_INFO_COUNT = 24/4 = 6。
// 之前只声明 20 字节（UInt64+UInt64+Int32），MemoryLayout.size=20 → count=20/4=5 ≠ 6
// → task_info 直接 KERN_FAILURE(4)，且缓冲区越界写 4 字节 —— 这就是"跨进程恒 kr=4"的真根因。
// v2.9.213：该结构不再用于 task_info（改 32 字节数组 + count=8，见 findImageLoadAddressDiag）。
// iOS16 TASK_DYLD_INFO 需要 32 字节（count=8），24 字节 count=6 恒 KERN_FAILURE(4)。
private struct TaskDyldInfoBuf {
    var all_image_info_addr: UInt64 = 0
    var all_image_info_size: UInt64 = 0
    var all_image_info_format: Int32 = 0
    var _pad: Int32 = 0
}

// MARK: - 纯 Swift Zip 打包器（Store 方法，零外部依赖）

enum ZipStorer {


    // v2.9.227: raw deflate (zip method 8) — 用 Compression 框架, 剥离 zlib 头(2B)+adler32尾(4B)
    static func deflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let dstCap = data.count + data.count / 2 + 256
        var dst = Data(count: dstCap)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            data.withUnsafeBytes { srcRaw -> Int in
                compression_encode_buffer(dstRaw.bindMemory(to: UInt8.self).baseAddress!, dstCap,
                                         srcRaw.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                         nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 4, written < data.count else { return nil }
        return Data(dst.prefix(written).dropFirst(2).dropLast(4))
    }

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
            guard let src = FileHandle(forReadingAtPath: f.abs) else { return false }
            defer { try? src.close() }
            let fileSize = (try? src.seekToEnd()) ?? 0
            try? src.seek(toFileOffset: 0)
            let size = UInt32(fileSize)
            let nameData = Data(f.rel.utf8)

            // v2.9.230: zlib 流式 deflate(单遍IO+C级crc32,内存~1MB,对齐SSZipArchive)
            // 228整文件deflate崩溃→改1MB分块; 229 store太慢太大→恢复压缩但流式
            var strm = z_stream()
            let initCode = deflateInit2_(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                                         Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initCode == Z_OK else { return false }
            defer { deflateEnd(&strm) }

            // Local File Header 占位(crc/csize 写完数据后回写)
            let lfhPos = offset
            var lfh = Data()
            appendU32(&lfh, 0x04034b50)
            appendU16(&lfh, 20)          // version needed
            appendU16(&lfh, 0x0800)      // flags: UTF-8
            appendU16(&lfh, 8)           // method: deflate
            appendU16(&lfh, 0)           // mod time
            appendU16(&lfh, 0)           // mod date
            appendU32(&lfh, 0)           // crc 占位
            appendU32(&lfh, 0)           // compSize 占位
            appendU32(&lfh, size)
            appendU16(&lfh, UInt16(nameData.count))
            appendU16(&lfh, 0)           // extra len
            lfh.append(nameData)
            out.write(lfh)
            offset += UInt64(lfh.count)

            // 流式 deflate 写数据
            let chunk = 1 << 20
            var inBuf = [UInt8](repeating: 0, count: chunk)
            var outBuf = [UInt8](repeating: 0, count: chunk + chunk / 2 + 256)
            var crcVal: uLong = 0
            var totalComp = 0
            while true {
                // 老API readData(ofLength:) (theos Swift 不认 read(into:upToCount:))
                let dataChunk = src.readData(ofLength: chunk)
                let have = dataChunk.count
                if have > 0 { dataChunk.copyBytes(to: &inBuf, count: have) }
                crcVal = inBuf.withUnsafeBytes { raw in
                    zlib.crc32(crcVal, raw.bindMemory(to: UInt8.self).baseAddress!, uInt(have))
                }
                strm.next_in = inBuf.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress }
                strm.avail_in = uInt(have)
                let flush: Int32 = (have == 0) ? Z_FINISH : Z_NO_FLUSH
                while true {
                    let outCap = outBuf.count
                    strm.next_out = outBuf.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress }
                    strm.avail_out = uInt(outCap)
                    let r = deflate(&strm, flush)
                    if r == Z_STREAM_ERROR { return false }
                    let produced = outCap - Int(strm.avail_out)
                    if produced > 0 { out.write(Data(outBuf[0..<produced])); totalComp += produced }
                    if strm.avail_out != 0 { break }
                }
                if flush == Z_FINISH { break }
            }
            let compSize = UInt32(totalComp)

            // 回写 LFH 的 crc(14) + compSize(18)
            var fix = Data()
            appendU32(&fix, UInt32(crcVal))
            appendU32(&fix, compSize)
            try? out.seek(toFileOffset: lfhPos + 14)
            out.write(fix)
            try? out.seek(toFileOffset: offset)

            // Central Directory Entry
            var cd = Data()
            appendU32(&cd, 0x02014b50)
            appendU16(&cd, 20)           // version made by
            appendU16(&cd, 20)           // version needed
            appendU16(&cd, 0x0800)
            appendU16(&cd, 8)
            appendU16(&cd, 0)            // time
            appendU16(&cd, 0)            // date
            appendU32(&cd, UInt32(crcVal))
            appendU32(&cd, compSize)
            appendU32(&cd, size)
            appendU16(&cd, UInt16(nameData.count))
            appendU16(&cd, 0)            // extra
            appendU16(&cd, 0)            // comment
            appendU16(&cd, 0)            // disk start
            appendU16(&cd, 0)            // internal attrs
            appendU32(&cd, 0)            // external attrs
            appendU32(&cd, UInt32(lfhPos))
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
