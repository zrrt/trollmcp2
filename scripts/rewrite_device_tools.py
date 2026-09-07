# -*- coding: utf-8 -*-
import io

p = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\AdvancedTools.swift'
s = io.open(p, encoding='utf-8').read()
i = s.find('final class DeviceFakeTool')
k = s.find('// MARK: - HTTP')
assert i > 0 and k > i, (i, k)

new_block = u'''final class DeviceFakeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.fake",
        summary: "设备伪装（内存注入版，v2.9.93）：写 fake_device.json 后向目标 App 进程内存注入 FakeDevice.dylib（opainject，不改二进制、零残留、重启还原）。默认 memory 模式绝不修改 App 文件，杜绝注入损坏。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "name": "伪装机型名称（如 iPhone 16 Pro Max）",
            "model": "伪装机型（如 iPhone）",
            "model_identifier": "伪装机型标识（如 iPhone17,2；部分 App 通过 sysctl 读取，仅作信息字段）",
            "system_version": "伪装系统版本（如 18.0）",
            "mode": "memory（默认，opainject 内存注入）/ file（旧式文件注入，风险高，仅特殊场景用）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \\(bundleId)"]
        }
        var config: [String: Any] = [:]
        if let name = params["name"] as? String, !name.isEmpty { config["name"] = name }
        if let model = params["model"] as? String, !model.isEmpty { config["model"] = model }
        if let mi = params["model_identifier"] as? String, !mi.isEmpty { config["modelIdentifier"] = mi }
        if let sv = params["system_version"] as? String, !sv.isEmpty { config["systemVersion"] = sv }
        guard !config.isEmpty else {
            throw MCPError.invalidParams("至少提供一个伪装字段（name/model/model_identifier/system_version）")
        }
        guard ProcessHelper.writeWorkspaceConfig("fake_device.json", dict: config) else {
            return ["error": "写入 fake_device.json 失败（工作区权限）"]
        }

        let mode = (params["mode"] as? String) ?? "memory"
        if mode == "file" {
            // 旧式文件注入：保留但明确标注风险
            let dylib = ProcessHelper.tweakPath("FakeDevice.dylib") ?? ""
            guard !dylib.isEmpty else { return ["error": "内置 FakeDevice.dylib 不存在"] }
            let r = try InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
            if (r["status"] as? String) != "injected" {
                return ["error": "FakeDevice 文件注入失败", "detail": r]
            }
            let exe = ProcessHelper.executableName(for: app)
            _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
            _ = ProcessHelper.launchApp(bundleId: bundleId)
            AuditLog.shared.log("device.fake.file", detail: "\\(bundleId) \\(config)")
            return [
                "status": "faked",
                "mode": "file",
                "bundle_id": bundleId,
                "app": app.name,
                "config": config,
                "config_path": "/var/mobile/Documents/Workspace/fake_device.json",
                "note": "文件注入已应用（改动 App 二进制，有备份）。恢复请用 device.restore"
            ]
        }

        // 默认：内存注入（opainject）——不碰任何文件
        let exeName = ProcessHelper.executableName(for: app)
        let dylib = ProcessHelper.tweakPath("FakeDevice.dylib") ?? ""
        guard !dylib.isEmpty, FileManager.default.fileExists(atPath: dylib) else {
            return ["error": "内置 FakeDevice.dylib 不存在", "hint": "检查 IPA 内 tweaks/FakeDevice.dylib"]
        }
        var pid = ProcessHelper.pidOf(executableName: exeName)
        if pid == nil {
            _ = ProcessHelper.launchApp(bundleId: bundleId)
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
        }
        guard let targetPid = pid else {
            return ["error": "目标 App 未能启动，无法内存注入", "hint": "手动打开目标 App 后重试"]
        }
        let (exit, output) = InjectionManager.shared.runAsRoot("opainject", args: ["\\(targetPid)", dylib])
        let ok = output.contains("dlopen succeeded") || (exit == 0 && output.contains("handle"))
        AuditLog.shared.log("device.fake.mem", detail: "\\(bundleId) pid=\\(targetPid) ok=\\(ok)")
        return [
            "status": ok ? "faked" : "failed",
            "mode": "memory",
            "bundle_id": bundleId,
            "app": app.name,
            "pid": targetPid,
            "config": config,
            "config_path": "/var/mobile/Documents/Workspace/fake_device.json",
            "exit": exit,
            "output": output,
            "note": ok
                ? "内存注入成功：FakeDevice 已在进程内生效，未改动任何文件；App 重启后自动还原真实设备"
                : "opainject 失败（见 output）。App 文件未被动过，无需恢复"
        ]
    }
}

final class DeviceRestoreTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.restore",
        summary: "还原设备伪装：删除 fake_device.json 并还原目标 App 真实设备信息。内存注入版：杀掉 App 进程即完全还原（零残留）；若之前是文件注入则完整卸载注入。",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let removed = ProcessHelper.removeWorkspaceConfig("fake_device.json")
        guard let app = AppCatalog.find(bundleId) else {
            return ["status": "restored", "bundle_id": bundleId, "config_removed": removed,
                    "injection_removed": false, "note": "App 未找到；已删除 fake_device.json"]
        }
        let exe = ProcessHelper.executableName(for: app)
        // 检查是否为文件注入（旧版遗留）
        let injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
        var injectionRemoved = false
        var restoreError = ""
        if injected {
            do {
                let r = try InjectionManager.shared.disable(bundleId: bundleId)
                injectionRemoved = ((r["status"] as? String) == "reverted") || !((r["restored_from_backup"] as? [String]) ?? []).isEmpty
                if !injectionRemoved {
                    restoreError = "disable 未确认还原（见 injection.disable 输出）"
                }
            } catch {
                restoreError = "恢复失败：\\(error.localizedDescription)"
                AuditLog.shared.log("device.restore.error", detail: "\\(bundleId) \\(restoreError)")
            }
        }
        // 内存注入：杀进程即还原；文件注入：杀进程确保新状态生效
        _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
        _ = ProcessHelper.launchApp(bundleId: bundleId)
        AuditLog.shared.log("device.restore", detail: "\\(bundleId) injected=\\(injected)")
        if !restoreError.isEmpty {
            return ["status": "error", "bundle_id": bundleId, "config_removed": removed,
                    "injection_removed": injectionRemoved, "error": restoreError,
                    "note": "fake_device.json 已删除并重启 App；但旧文件注入卸载失败，请用「注入与自动化」页的紧急恢复一键全恢复"]
        }
        return [
            "status": "restored",
            "bundle_id": bundleId,
            "config_removed": removed,
            "injection_removed": injectionRemoved,
            "mode": injected ? "file" : "memory",
            "note": injected
                ? "已删除 fake_device.json、卸载旧文件注入并重启 App"
                : "已删除 fake_device.json 并重启 App（内存注入随进程结束自动消失，零残留）"
        ]
    }
}

'''
s = s[:i] + new_block + s[k:]
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('replaced OK, new len:', len(s))
