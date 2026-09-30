import Foundation
import CryptoKit

/// v4.3.32: 一键二进制安全/逆向扫描报告工具。
/// 用户痛点: "ai_analyze 里很多集合工具没意义——AI 不会自己主动调用不同工具去分析"。
/// 设计: 一次调用自动完成 侦察+静态 两步(格式/架构/加密/依赖/哈希/熵 → 字符串/域名/敏感API/混淆
///       → ObjC 类与方法选择器 → 风险评分+命中证据行+结论)，AI 拿报告即可决策，无需手动编排多工具。
/// 边界: 深度反编译/许可逻辑还原在电脑侧(Ghidra/rizin/llvm)；本工具做 App 内能做的全部。
struct BinaryScanTool: MCPTool {
    let definition = ToolDefinition(
        name: "binary.scan",
        summary: "One-shot binary security/reverse-engineering scan report. Use for: vet a plugin/dylib/app binary for backdoors (contacts/SMS/exfil/remote-control), quick RE triage, decide if a binary is safe before trusting it. Internal steps are ALL automatic: format/arch/encryption/dependencies/SHA256/entropy → strings/URLs/domains/sensitive-API hits/obfuscation → ObjC classes + method selectors → risk score + evidence lines + verdict. Don't use for: deep decompilation (use PC-side Ghidra/rizin), app behavior analysis (use app ai_analyze), injecting hooks (use inject.*). Example: user asks '这个插件安全吗' → binary.scan path:<plugin.dylib>.",
        parameters: [
            "path": "Path to binary (Mach-O dylib/executable, or extracted ipa/deb payload binary)",
            "limit": "Max items per list (default 60)"
        ],
        verified: true, category: "analysis")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        let limit = (params["limit"] as? Int) ?? 60
        guard FileManager.default.fileExists(atPath: path) else {
            return ["error": "file not found: \(path)"]
        }

        var report: [String: Any] = ["path": path]

        // ── 0. 侦察: 体积 + SHA256 + Mach-O 头/依赖/加密 ──
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        let fileSize = size?.int64Value ?? 0
        report["file"] = ["size_bytes": fileSize,
                          "sha256": sha256Hex(path: path) ?? "unreadable"]

        let mo = MachOAnalyzer.analyze(path)
        var macho: [String: Any] = [:]
        if let mo {
            macho["valid"] = mo.valid
            macho["arch"] = mo.arch
            macho["file_type"] = machoFileTypeName(mo.fileType)
            macho["file_type_code"] = mo.fileType
            macho["encrypted_cryptid"] = mo.cryptID
            macho["code_signature"] = mo.hasCodeSignature
            macho["dylibs"] = mo.dylibs
        } else {
            macho["valid"] = false
            macho["hint"] = "not a Mach-O (maybe ELF/ipa/zip/plain text — run file on it)"
        }
        report["macho"] = macho

        // ── 1. 静态: 字符串(分块原生读) + 域名 + 敏感API + 混淆迹象 ──
        let stringsResult = extractStrings(path: path, maxBytes: 384 * 1024 * 1024)
        let allStrings = stringsResult.strings
        report["strings"] = ["total": allStrings.count, "sample": Array(allStrings.prefix(limit))]

        let urls = extractURLs(from: allStrings)
        let domains = extractDomains(from: urls, skipKnownGood: true)
        report["network"] = ["urls": Array(urls.prefix(limit)),
                             "external_domains": Array(domains.prefix(limit)),
                             "external_domain_count": domains.count]

        // 敏感 API 分类命中(带证据行)
        let sens = scanSensitive(allStrings)
        report["sensitive_hits"] = sens.hits   // [category: [evidence...]]
        report["sensitive_count"] = sens.total

        // 混淆/加壳迹象: 熵 + 字符串密度 + 随机符号
        let entropy = sampleEntropy(path: path, sampleBytes: 1_048_576)
        let density = fileSize > 0 ? Double(stringsResult.printableBytes) / Double(fileSize) : 0
        var obf: [String: Any] = ["entropy_1MB_sample": String(format: "%.2f", entropy),
                                  "string_density": String(format: "%.3f", density)]
        if entropy > 7.5 { obf["signal"] = "high_entropy — likely packed/encrypted __TEXT" }
        if density < 0.05 && fileSize > 100_000 { obf["signal"] = "very_low_string_density — likely packed/encrypted" }
        if allStrings.contains(where: { $0.localizedCaseInsensitiveContains("upx") || $0.contains("UPX!") }) {
            obf["signal"] = "UPX packer marker found"
        }
        report["obfuscation"] = obf

        // ── 2. ObjC 元数据: 类名 + 方法选择器(直读 __objc_classname / __objc_methname 段) ──
        let objc = readObjCSections(path: path)
        report["objc"] = ["classes": Array(objc.classes.prefix(limit)),
                          "class_count": objc.classes.count,
                          "method_selectors": Array(objc.selectors.prefix(limit)),
                          "method_count": objc.selectors.count]

        // ── 3. 风险评分 + 结论 ──
        let risk = scoreRisk(sens: sens, domains: domains, obf: obf, macho: macho,
                             classes: objc.classes, selectors: objc.selectors)
        report["risk"] = ["score": risk.score, "level": risk.level,
                          "findings": risk.findings, "verdict": risk.verdict]
        report["note"] = "Evidence-based triage. Deep decompilation (Ghidra/rizin) is PC-side; dynamic network check: network.capture."

        return report
    }

    // MARK: - 侦察

    private func sha256Hex(path: String) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024
        var total = 0
        while let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += chunk.count
            if total > 512 * 1024 * 1024 { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func machoFileTypeName(_ t: UInt32) -> String {
        switch t {
        case 0x1: return "MH_OBJECT (relocatable object)"
        case 0x2: return "MH_EXECUTE (executable)"
        case 0x4: return "MH_FVMLIB"
        case 0x6: return "MH_DYLIB (dynamic library)"
        case 0x7: return "MH_DYLINKER (dyld)"
        case 0x8: return "MH_BUNDLE (plugin bundle)"
        case 0xa: return "MH_DYLIB_STUB"
        case 0xb: return "MH_DSYM"
        default: return "type \(t)"
        }
    }

    // MARK: - 静态

    private struct StringsResult { let strings: [String]; let printableBytes: Int }

    private func extractStrings(path: String, maxBytes: Int) -> StringsResult {
        guard let handle = FileHandle(forReadingAtPath: path) else { return StringsResult(strings: [], printableBytes: 0) }
        defer { try? handle.close() }
        let chunkSize = 4 * 1024 * 1024
        var out: [String] = []
        var tail = Data()
        var total = 0
        var printable = 0
        var cap = 200_000
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            total += chunk.count
            if total > maxBytes { break }
            var buf = tail; buf.append(chunk)
            var cur = Data()
            for byte in buf {
                if byte >= 0x20 && byte <= 0x7e {
                    cur.append(byte)
                } else {
                    if cur.count >= 4 {
                        if let s = String(data: cur, encoding: .utf8) {
                            if out.count < cap { out.append(s) }
                            printable += cur.count
                        }
                    }
                    cur = Data()
                }
            }
            tail = cur
        }
        if tail.count >= 4, let s = String(data: tail, encoding: .utf8) {
            if out.count < cap { out.append(s) }
            printable += tail.count
        }
        return StringsResult(strings: out, printableBytes: printable)
    }

    private func extractURLs(from strings: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let pattern = #"https?://[A-Za-z0-9\.\-_:/?&=#%@+~\[\]\(\)!$,;*']{4,}"#
        for s in strings {
            guard s.count < 4096 else { continue }
            if let range = s.range(of: pattern, options: .regularExpression) {
                let u = String(s[range])
                if !seen.contains(u) { seen.insert(u); out.append(u) }
            }
        }
        return out
    }

    private func extractDomains(from urls: [String], skipKnownGood: Bool) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let knownGood = ["apple.com", "apple-cloudkit.com", "icloud.com", "mzstatic.com",
                         "google.com", "gstatic.com", "googleapis.com", "facebook.com",
                         "fbcdn.net", "amazonaws.com", "amazon.com", "microsoft.com",
                         "windows.net", "cloudflare.com", "cloudflare-dns.com", "github.com",
                         "githubusercontent.com", "doubleclick.net", "chartboost.com",
                         "unity3d.com", "unityads.unity3d.com", "applovin.com", "ironsrc.mobi",
                         "vungle.com", "tapjoy.com", "kochava.com", "adjust.com", "branch.io",
                         "appsflyer.com", "firebaseio.com", "crashlytics.com", "sentry.io",
                         "bugsnag.com", "amplitude.com", "mixpanel.com", "segment.com",
                         "leanplum.com", "intercom.io", "zendesk.com", "fabric.io",
                         "tencent.com", "qq.com", "taobao.com", "alibaba.com", "aliyuncs.com",
                         "bytedance.com", "toutiao.com", "pangle.io", "volcengine.com",
                         "baidu.com", "xiaomi.com", "mi.com", "huawei.com", "weixin.qq.com"]
        for u in urls {
            guard let comp = URL(string: u), let host = comp.host else { continue }
            var h = host.lowercased()
            if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
            if skipKnownGood, knownGood.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { continue }
            if !seen.contains(h) { seen.insert(h); out.append(h) }
        }
        return out
    }

    // 敏感 API 分类: 每类返回命中证据行(去重, 最多 8 条)
    private struct SensitiveResult { let hits: [String: [String]]; let total: Int }

    private func scanSensitive(_ strings: [String]) -> SensitiveResult {
        let categories: [(String, [String])] = [
            ("privacy_contacts", ["CNContact", "CNContactStore", "AddressBook", "ABAddressBook", "ABPerson", "Contacts framework", "unifiedContacts"]),
            ("privacy_sms_call", ["CTMessage", "CTMessageCenter", "SMS", "ABMultiValue", "callLog", "CallKit", "CXCallController"]),
            ("privacy_location", ["CLLocationManager", "CLLocation", "startUpdatingLocation", "locationServicesEnabled", "geolocation"]),
            ("privacy_photos_media", ["PHPhotoLibrary", "PHAsset", "AVCapture", "UIImagePickerController", "recordAudio", "AVAudioRecorder", "UIPasteboard", "generalPasteboard"]),
            ("privacy_files", ["NSFileManager", "contentsOfDirectory", "enumeratorAtPath", "Documents/", "Library/", "readDataFromFile"]),
            ("keychain", ["SecItemAdd", "SecItemCopyMatching", "kSecClass", "SecKey", "keychain", "kSecAttrAccount", "KC_"]),
            ("dynamic_load_exec", ["dlopen", "dlsym", "NSClassFromString", "performSelector", "objc_getClass", "dlsym(", "class_addMethod"]),
            ("network_upload_exfil", ["NSURLSession", "uploadTask", "dataTask", "CFNetwork", "multipart/form-data", "POST ", "http://", "socket", "connect(", "sendData", "NSOutputStream", "Base64", "base64"]),
            ("remote_control", ["system(", "NSTask", "posix_spawn", "fork", "launchd", "SBSLaunchApplication", "UIApplication openURL", "installApp", "downloadTask", "subprocess", "NSAppleScript"]),
            ("persistence_rootkit", ["LaunchDaemons", "LaunchAgents", "com.apple.dylib", "DYLD_INSERT_LIBRARIES", "insert_dylib", "ldid", "codesign", "entitlements", "setuid", "setgid", "chmod 755"])
        ]
        var hits: [String: [String]] = [:]
        var seen: [String: Set<String>] = [:]
        var total = 0
        for (cat, kws) in categories {
            for s in strings {
                guard s.count < 2048 else { continue }
                if kws.contains(where: { s.localizedCaseInsensitiveContains($0) }) {
                    total += 1
                    if seen[cat, default: []].count < 8 {
                        seen[cat, default: []].insert(s)
                    }
                }
            }
            if let v = seen[cat], !v.isEmpty {
                hits[cat] = Array(v)
            }
        }
        return SensitiveResult(hits: hits, total: total)
    }

    private func sampleEntropy(path: String, sampleBytes: Int) -> Double {
        guard let fh = try? FileHandle(forReadingAtPath: path),
              let data = try? fh.read(upToCount: sampleBytes), !data.isEmpty else { return 0 }
        var counts = [UInt8: Int]()
        for b in data { counts[b, default: 0] += 1 }
        let n = Double(data.count)
        var h = 0.0
        for (_, c) in counts {
            let p = Double(c) / n
            h -= p * log2(p)
        }
        return h
    }

    // MARK: - ObjC 元数据(直读段)

    private struct ObjCInfo { let classes: [String]; let selectors: [String] }

    private func readObjCSections(path: String) -> ObjCInfo {
        // 解析 load commands 找 __TEXT,__objc_classname 与 __TEXT,__objc_methname
        guard let fh = try? FileHandle(forReadingAtPath: path) else { return ObjCInfo(classes: [], selectors: []) }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 8 * 1024 * 1024), head.count >= 8 else {
            return ObjCInfo(classes: [], selectors: [])
        }
        var offset = 0
        let magic = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        var effectiveMagic = magic
        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            let countRaw = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let count = magic == 0xCAFEBABE ? countRaw.byteSwapped : countRaw
            var found: UInt32?
            for i in 0..<min(count, 16) {
                let off = 8 + Int(i) * 20
                guard head.count >= off + 12 else { break }
                let cpuRaw = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
                let cpu = magic == 0xCAFEBABE ? cpuRaw.byteSwapped : cpuRaw
                if cpu == 0x0100000C {
                    let so = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self) }
                    found = magic == 0xCAFEBABE ? so.byteSwapped : so
                    break
                }
            }
            guard let f = found else { return ObjCInfo(classes: [], selectors: []) }
            offset = Int(f)
            guard head.count >= offset + 8 else { return ObjCInfo(classes: [], selectors: []) }
            effectiveMagic = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard effectiveMagic == 0xFEEDFACF else { return ObjCInfo(classes: [], selectors: []) }  // 仅 64 位
        let headerSize = 32
        guard head.count >= offset + headerSize + 8 else { return ObjCInfo(classes: [], selectors: []) }
        let ncmds = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self) }
        let sizeofcmds = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 20, as: UInt32.self) }

        var cursor = offset + headerSize
        let cmdEnd = offset + headerSize + Int(sizeofcmds)
        var remain = Int(ncmds)
        var methSection: (off: UInt64, size: UInt64)?
        var clsSection: (off: UInt64, size: UInt64)?
        while cursor + 8 <= cmdEnd, remain > 0, head.count >= cursor + 8 {
            let cmd = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
            let cmdsizeRaw = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self) }
            let cmdsize = Int(cmdsizeRaw)
            guard cmdsize >= 72, cursor + cmdsize <= cmdEnd, head.count >= cursor + cmdsize else { break }
            if cmd == 0x19 {  // LC_SEGMENT_64
                let nsectsRaw = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 64, as: UInt32.self) }
                let nsects = Int(nsectsRaw)
                var s = cursor + 72
                for _ in 0..<min(nsects, 64) {
                    guard s + 80 <= cursor + cmdsize, head.count >= s + 80 else { break }
                    let sectName = readCString(head, at: s, len: 16)
                    let segName = readCString(head, at: s + 16, len: 16)
                    let so = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: s + 40, as: UInt64.self) }
                    let sz = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: s + 48, as: UInt64.self) }
                    if segName == "__TEXT", sectName == "__objc_methname" { methSection = (so, sz) }
                    if segName == "__TEXT", sectName == "__objc_classname" { clsSection = (so, sz) }
                    s += 80
                }
            }
            cursor += cmdsize
            remain -= 1
        }
        let classes = readSectionStrings(path: path, sec: clsSection, fh: fh)
        let selectors = readSectionStrings(path: path, sec: methSection, fh: fh)
        return ObjCInfo(classes: classes, selectors: selectors)
    }

    private func readCString(_ data: Data, at offset: Int, len: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: len)
        data.copyBytes(to: &bytes, from: offset..<min(offset + len, data.count))
        if let nul = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<nul]) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func readSectionStrings(path: String, sec: (off: UInt64, size: UInt64)?, fh: FileHandle) -> [String] {
        guard let sec, sec.size > 0, sec.size < 64 * 1024 * 1024 else { return [] }
        guard let orig = try? fh.offset() else { return [] }
        defer { try? fh.seek(toOffset: orig) }
        guard (try? fh.seek(toOffset: sec.off)) != nil,
              let data = try? fh.read(upToCount: Int(sec.size)), !data.isEmpty else { return [] }
        var out: [String] = []
        var cur = Data()
        for b in data {
            if b == 0 {
                if cur.count >= 2, let s = String(data: cur, encoding: .utf8) { out.append(s) }
                cur = Data()
            } else { cur.append(b) }
        }
        if cur.count >= 2, let s = String(data: cur, encoding: .utf8) { out.append(s) }
        return out
    }

    // MARK: - 风险评分

    private func scoreRisk(sens: SensitiveResult, domains: [String], obf: [String: Any],
                           macho: [String: Any], classes: [String], selectors: [String]) -> (score: Int, level: String, findings: [String], verdict: String) {
        var score = 0
        var findings: [String] = []
        let catScore: [String: Int] = [
            "privacy_contacts": 30, "privacy_sms_call": 30, "privacy_location": 22, "privacy_photos_media": 22,
            "keychain": 18, "dynamic_load_exec": 20, "network_upload_exfil": 25, "remote_control": 28,
            "persistence_rootkit": 26, "privacy_files": 10
        ]
        for (cat, ev) in sens.hits {
            let w = catScore[cat] ?? 8
            score += w
            findings.append("\(cat): \(ev.count) hits — e.g. \(ev.prefix(2).joined(separator: " | "))")
        }
        // 敏感类名(SS*/License 等许可校验特征)提示
        if let lic = classes.first(where: { $0.localizedCaseInsensitiveContains("license") || $0.hasPrefix("SS") }) {
            score += 6
            findings.append("license/SS-style class present: \(lic) — commercial-license verification or repackaging signal")
        }
        // 混淆/加壳
        if let signal = obf["signal"] as? String {
            score += 12
            findings.append("obfuscation: \(signal)")
        }
        // 外连域名
        if !domains.isEmpty {
            score += min(domains.count * 4, 20)
            findings.append("external domains: \(domains.prefix(6).joined(separator: ", "))\(domains.count > 6 ? " +\(domains.count - 6) more" : "")")
        }
        // 加密态
        if let crypt = macho["encrypted_cryptid"] as? UInt32, crypt > 0 {
            score += 8
            findings.append("encrypted (cryptid=\(crypt)) — decrypt before analysis")
        }
        // 依赖异常提示: 纯 JSON/工具库链了重型系统框架
        if let dylibs = macho["dylibs"] as? [String] {
            let heavy = dylibs.filter { $0.localizedCaseInsensitiveContains("WebKit") || $0.localizedCaseInsensitiveContains("Metal") || $0.localizedCaseInsensitiveContains("Network") || $0.localizedCaseInsensitiveContains("AudioToolbox") || $0.localizedCaseInsensitiveContains("Security") }
            if !heavy.isEmpty {
                score += 8
                findings.append("heavy frameworks linked (\(heavy.joined(separator: ", "))) — oversized surface for a plain utility, repackaging signal")
            }
        }
        // 无符号表
        let dynSymPresent = selectors.count > 0 || classes.count > 0
        _ = dynSymPresent

        let level = score >= 50 ? "高风险" : (score >= 20 ? "中风险" : (score >= 5 ? "低风险/需注意" : "未见明显风险"))
        var verdict: String
        switch level {
        case "高风险":
            verdict = "存在多项恶意/后门特征组合(隐私API/回连/动态加载/强混淆)。不建议直接使用，需电脑侧 Ghidra 深挖 + 真机 network.capture 动态验证。"
        case "中风险":
            verdict = "检出可疑特征(需人工判断是否正常业务所需)。建议真机 network.capture 观察实际回连行为后再决定。"
        default:
            verdict = "未检出明显恶意特征。仍建议仅在受控环境运行陌生二进制。"
        }
        return (score, level, findings, verdict)
    }
}
