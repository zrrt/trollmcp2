import io

p = r'Sources\TrollMCP2\InjectionManager.swift'
s = io.open(p, encoding='utf-8').read()
orig = s

# 1) Info struct 加字段
old1 = '''    struct Info {
        var arch: String
        var cryptID: UInt32
        var dylibs: [String]
        var valid: Bool
    }'''
new1 = '''    struct Info {
        var arch: String
        var cryptID: UInt32
        var dylibs: [String]
        var valid: Bool
        var fileType: UInt32 = 0
        var hasCodeSignature: Bool = false
    }'''
assert old1 in s, 'info'
s = s.replace(old1, new1)

# 2) analyze：读 fileType + 记 LC_CODE_SIGNATURE
old2 = '''        let ncmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self) }'''
new2 = '''        let fileType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self) }
        let ncmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self) }'''
assert old2 in s, 'filetype'
s = s.replace(old2, new2)

old3 = '''            case lcEncryptionInfo, lcEncryptionInfo64:
                if cursor + 20 <= data.count {
                    cryptID = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 16, as: UInt32.self) }
                }
            default:'''
new3 = '''            case lcEncryptionInfo, lcEncryptionInfo64:
                if cursor + 20 <= data.count {
                    cryptID = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 16, as: UInt32.self) }
                }
            case 0x1D:   // LC_CODE_SIGNATURE
                hasCodeSignature = true
            default:'''
assert old3 in s, 'lc_code_signature'
s = s.replace(old3, new3)

old4 = '''        return Info(arch: is64 ? "arm64" : "arm32", cryptID: cryptID, dylibs: dylibs, valid: true)'''
new4 = '''        return Info(arch: is64 ? "arm64" : "arm32", cryptID: cryptID, dylibs: dylibs, valid: true,
                    fileType: fileType, hasCodeSignature: hasCodeSignature)'''
assert old4 in s, 'ret'
s = s.replace(old4, new4)

# 3) pseudoSign 重写（对齐 TrollFools：条件跳过 + 保留 entitlements）
old5 = '''    /// 伪签（对齐 TrollFools cmdPseudoSign：改 Mach-O 前必须 ldid -S，否则 __LINKEDIT 顺序问题）
    @discardableResult
    private func pseudoSign(_ target: String) -> (Int32, String) {
        runAsRoot("ldid", args: ["-S", target])
    }'''
new5 = '''    /// 伪签（对齐 TrollFools cmdPseudoSign）：
    /// - 已有代码签名且非 force → 跳过，避免二次签名破坏原签名（v2.9.104 修复：此前无条件 ldid -S
    ///   会把主二进制的 entitlements 抹掉 → App 启动被 amfid 拒 → 注入后闪退）
    /// - 主二进制（MH_EXECUTE=0x2）→ 保留 entitlements：ldid -e 提取 → -S<xml> 重签
    /// - 无签名 → ldid -S
    @discardableResult
    private func pseudoSign(_ target: String, force: Bool = false) -> (Int32, String) {
        guard let info = MachOAnalyzer.analyze(target), info.valid else {
            return runAsRoot("ldid", args: ["-S", target])
        }
        guard force || !info.hasCodeSignature else {
            return (0, "skip: already signed")
        }
        if info.fileType == 0x2 {
            let (c1, o1) = runAsRoot("ldid", args: ["-e", target])
            if c1 == 0 {
                let trimmed = o1.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let xmlPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ent_\\(UUID().uuidString).xml")
                    do {
                        try trimmed.write(toFile: xmlPath, atomically: true, encoding: .utf8)
                        return runAsRoot("ldid", args: ["-S\\(xmlPath)", target])
                    } catch {}
                }
            }
            return (c1, o1)
        }
        return runAsRoot("ldid", args: ["-S", target])
    }'''
assert old5 in s, 'pseudosign'
s = s.replace(old5, new5)

# 4) coreTrustBypass：条件伪签 + teamID
old6 = '''    /// CoreTrust 重签 + 属主（对齐 TrollFools cmdCoreTrustBypass + cmdChangeOwnerToInstalld）
    @discardableResult
    private func coreTrustBypass(_ target: String) -> (Int32, String) {
        let (c, o) = runAsRoot("ct_bypass", args: ["-r", "-i", target, "-t", "TROLLTROLL"])
        _ = runAsRoot("chown", args: ["33:33", target])
        return (c, o)
    }'''
new6 = '''    /// CoreTrust 重签 + 属主（对齐 TrollFools cmdCoreTrustBypass + cmdChangeOwnerToInstalld）
    /// v2.9.104：teamID 用目标 App 真实 TeamID（TrollFools 用 LSApplicationProxy.teamID()），
    /// fallback TROLLTROLL——部分 App 对签名 TeamID 有校验，固定 TROLLTROLL 会被拒启动
    @discardableResult
    private func coreTrustBypass(_ target: String, teamID: String = "TROLLTROLL") -> (Int32, String) {
        _ = pseudoSign(target)
        let (c, o) = runAsRoot("ct_bypass", args: ["-r", "-i", target, "-t", teamID])
        _ = runAsRoot("chown", args: ["33:33", target])
        return (c, o)
    }

    /// 目标 App 真实 TeamID（对齐 TrollFools AppListModel：LSApplicationProxy.teamID()）
    private func realTeamID(for bundleId: String) -> String {
        if let proxy = LSApplicationProxy(forIdentifier: bundleId), let tid = proxy.teamID(), !tid.isEmpty {
            return tid
        }
        return "TROLLTROLL"
    }'''
assert old6 in s, 'ctbypass'
s = s.replace(old6, new6)

# 5) enable 流程：7a force + 7d 去掉重复无条件伪签、换真实 teamID
old7 = '''            // 7a. 改前伪签（对齐 TrollFools cmdPseudoSign force）——修掉 install_name_tool LINKEDIT 报错
            let (ps, pso) = pseudoSign(targetMachO)'''
new7 = '''            // 7a. 改前伪签（对齐 TrollFools cmdPseudoSign force）——修掉 install_name_tool LINKEDIT 报错
            let (ps, pso) = pseudoSign(targetMachO, force: true)'''
assert old7 in s, '7a'
s = s.replace(old7, new7)

old8 = '''            // 7d. 重签：ldid -S + ct_bypass + chown
            _ = pseudoSign(targetMachO)
            _ = coreTrustBypass(targetMachO)'''
new8 = '''            // 7d. 重签：条件伪签（保留 entitlements）+ ct_bypass（真实 teamID）+ chown
            _ = coreTrustBypass(targetMachO, teamID: realTeamID(for: bundleId))'''
assert old8 in s, '7d'
s = s.replace(old8, new8)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('OK patched, diff len:', len(s) - len(orig))
