import io
p = r'Sources\TrollMCP2\InjectionManager.swift'
s = io.open(p, encoding='utf-8').read()

old1 = '''        let fileType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self) }
        let ncmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self) }'''
new1 = '''        let fileType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self) }
        var hasCodeSignature = false
        let ncmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self) }'''
assert old1 in s, 'var decl'
s = s.replace(old1, new1)

old2 = '''    /// 目标 App 真实 TeamID（对齐 TrollFools AppListModel：LSApplicationProxy.teamID()）
    private func realTeamID(for bundleId: String) -> String {
        if let proxy = LSApplicationProxy(forIdentifier: bundleId), let tid = proxy.teamID(), !tid.isEmpty {
            return tid
        }
        return "TROLLTROLL"
    }'''
new2 = '''    /// 目标 App 真实 TeamID：从主二进制既有签名的 entitlements（application-identifier = TEAMID.bundleId）
    /// 提取前缀——零外部依赖（不用 LSApplicationProxy），对齐 TrollFools teamID() 的效果
    private func realTeamID(for bundleId: String, appPath: String?) -> String {
        guard let main = appPath else { return "TROLLTROLL" }
        let (c, o) = runAsRoot("ldid", args: ["-e", main])
        guard c == 0, let r = o.range(of: "application-identifier"), o.contains(bundleId) else {
            return "TROLLTROLL"
        }
        let tail = o[r.upperBound...]
        if let open = tail.range(of: "<string>"), let close = tail.range(of: "</string>") {
            let val = String(tail[open.upperBound..<close.lowerBound])
            if val.hasSuffix(bundleId) {
                let team = String(val.dropLast(bundleId.count))
                if !team.isEmpty { return team }
            }
        }
        return "TROLLTROLL"
    }'''
assert old2 in s, 'realTeamID'
s = s.replace(old2, new2)

old3 = '''            _ = coreTrustBypass(targetMachO, teamID: realTeamID(for: bundleId))'''
new3 = '''            _ = coreTrustBypass(targetMachO, teamID: realTeamID(for: bundleId, appPath: executablePath(app)))'''
assert old3 in s, 'call'
s = s.replace(old3, new3)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('OK2')
