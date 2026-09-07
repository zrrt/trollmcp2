# -*- coding: utf-8 -*-
import io

path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\AdvancedTools.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

old = """        if groups.isEmpty { groups = ["TROLLTROLL.dev.trollmcp2.app"] }
        var deleted = 0
        var failed = 0
        var errors: [String] = []
        for g in groups {"""

new = """        if groups.isEmpty { groups = ["TROLLTROLL.dev.trollmcp2.app"] }
        var deleted = 0
        var failed = 0
        var errors: [String] = []
        // v2.9.96：优先 root 直改 keychain-2.db（sqlite_wipe 内置工具），
        // 不受跨组 entitlements 限制，精确删除目标 App 全部钥匙串条目。
        let im = InjectionManager.shared
        let (rc, rout) = im.runAsRoot("sqlite_wipe", args: ["sqlite_wipe"] + groups)
        if rc == 0 {
            let tokens = rout.split(separator: " ")
            let wiped = (tokens.count >= 3 ? Int(tokens[1]) : nil) ?? 0
            return [
                "bundle_id": bundleId,
                "method": "sqlite_wipe(root keychain-2.db)",
                "groups_tried": groups,
                "deleted_count": wiped,
                "output": rout.trimmingCharacters(in: .whitespacesAndNewlines),
                "hint": "已按 keychain-access-groups 从系统 keychain 数据库删除目标 App 条目（登录态将被重置）。如 App 仍在运行，建议杀进程后重启"
            ]
        }
        errors.append("sqlite_wipe: \\(rc) \\(rout)")
        // fallback：SecItemDelete（受本 App entitlements 限制，尽量删自己组）
        for g in groups {"""

assert old in c, 'pattern not found'
c = c.replace(old, new)
with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('PATCHED')
