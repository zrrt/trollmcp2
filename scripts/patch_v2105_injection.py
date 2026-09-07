import io
p = r'Sources\TrollMCP2\InjectionManager.swift'
s = io.open(p, encoding='utf-8').read()

# 1) enable: 源 dylib ct_bypass 用真实 teamID（对齐 TrollFools 日志 T8ALTGMVXN）
old1 = '''        // 4. 预处理源 dylib：ct_bypass + chown（对齐 TrollFools applyCoreTrustBypass）
        let (pc, po) = runAsRoot("ct_bypass", args: ["-r", "-i", agentSrc, "-t", "TROLLTROLL"])'''
new1 = '''        // 4. 预处理源 dylib：ct_bypass + chown（对齐 TrollFools applyCoreTrustBypass）
        let (pc, po) = runAsRoot("ct_bypass", args: ["-r", "-i", agentSrc, "-t", realTeamID(for: bundleId, appPath: executablePath(app))])'''
assert old1 in s, 'src ct_bypass'
s = s.replace(old1, new1)

# 2) enable: insert_dylib 加 --weak（对齐 TrollFools 铁证：LC_LOAD_WEAK_DYLIB → dylib 加载失败不闪退）
old2 = '''            let (c1, o1) = runAsRoot("insert_dylib", args: [injectName, targetMachO, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes"])'''
new2 = '''            let (c1, o1) = runAsRoot("insert_dylib", args: [injectName, targetMachO, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes", "--weak"])'''
assert old2 in s, 'weak'
s = s.replace(old2, new2)

# 3) disable 重写：先删资产文件 → 有备份的直接 restore（还原干净二进制，跳过 optool+重签）→ 无备份的才 optool+重签（真实 teamID）
old3 = '''        // 1. 移除每个注入资产的加载命令
        for asset in assets {
            let assetName: String
            if (asset as NSString).pathExtension == "framework" {
                let fwName = (asset as NSString).lastPathComponent
                let exeName = (fwName as NSString).deletingPathExtension
                assetName = "@rpath/\\(fwName)/\\(exeName)"
            } else {
                assetName = "@rpath/\\((asset as NSString).lastPathComponent)"
            }
            var removedFrom: [String] = []
            for target in modified {
                let (c, o) = removeLoadCommand(assetName: assetName, from: target)
                if c == 0 { removedFrom.append(target) }
                else { AuditLog.shared.log("injection.disable.optool", detail: "\\(assetName) @ \\(target): exit=\\(c) \\(o)") }
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
        }'''
new3 = '''        // 1. 先删除注入资产文件（对齐 TrollFools eject：cmdRemove asset）
        for asset in assets {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: asset, isDirectory: &isDir)
            let (cD, _) = runAsRoot("rm", args: [isDir.boolValue ? "-rf" : "-f", asset])
            if cD == 0 { removedAssets.append(asset) }
        }

        // 2. 有备份的 Mach-O 直接 restore（备份 = 注入前原二进制，还原后无需 optool/重签；
        //    v2.9.105 修复：此前先 coreTrustBypass(TROLLTROLL) 再 restore，重签本身会破坏签名 → 删除也闪退）
        var restored: [String] = []
        var remaining: [String] = []
        for target in modified {
            if hasAlternate(target) {
                if (try? restoreAlternate(target)) == true {
                    restored.append(target)
                    continue
                }
            }
            remaining.append(target)
        }

        // 3. 无备份的 target 才手工清理：optool uninstall + 重签（真实 teamID，对齐 TrollFools eject）
        for target in remaining {
            for asset in assets {
                let assetName: String
                if (asset as NSString).pathExtension == "framework" {
                    let fwName = (asset as NSString).lastPathComponent
                    let exeName = (fwName as NSString).deletingPathExtension
                    assetName = "@rpath/\\(fwName)/\\(exeName)"
                } else {
                    assetName = "@rpath/\\((asset as NSString).lastPathComponent)"
                }
                let (c, o) = removeLoadCommand(assetName: assetName, from: target)
                if c == 0 { removedLoads[assetName] = (removedLoads[assetName] ?? []) + [target] }
                else { AuditLog.shared.log("injection.disable.optool", detail: "\\(assetName) @ \\(target): exit=\\(c) \\(o)") }
            }
            _ = coreTrustBypass(target, teamID: realTeamID(for: bundleId, appPath: executablePath(app)))
        }'''
assert old3 in s, 'disable'
s = s.replace(old3, new3)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('OK105')
