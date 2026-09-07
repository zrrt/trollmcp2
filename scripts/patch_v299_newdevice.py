# -*- coding: utf-8 -*-
import io

# ============ NewDeviceTool 追加到 AdvancedTools.swift 尾部 ============
path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\AdvancedTools.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

tool = '''
// MARK: - v2.9.99 一键新机（绿盾式组合）

/// automation.new_device — 一键新机：整机 keychain 重置 + 广告符刷新 + 设备伪装组合
/// 组合复用 KeychainResetTool / AdvertisingTool / DeviceFakeTool，一步完成"新机"环境。
final class NewDeviceTool: MCPTool {
    let definition = ToolDefinition(
        name: "automation.new_device",
        summary: "一键新机（绿盾式组合，v2.9.99）：整机 keychain 重置 + 广告符刷新 + 设备伪装写入。⚠️ 会清空所有 App 登录态，慎用。传 bundle_id 则同时向目标 App 内存注入 FakeDevice.dylib",
        parameters: [
            "bundle_id": "目标 App Bundle ID（可选；传入则写伪装配置后立即内存注入 FakeDevice.dylib）",
            "name": "伪装机型名称（默认 iPhone 16 Pro Max）",
            "model": "伪装机型（默认 iPhone）",
            "model_identifier": "机型标识（默认 iPhone17,2）",
            "system_version": "伪装系统版本（默认 18.0）",
            "reset_keychain": "是否清空整机 keychain（默认 true）",
            "refresh_idfa": "是否尝试刷新广告符（默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        var steps: [[String: Any]] = []
        var warnings: [String] = []

        let resetKC = (params["reset_keychain"] as? Bool) ?? true
        if resetKC {
            do {
                steps.append(["step": "keychain_reset", "result": try KeychainResetTool().invoke([:])])
            } catch let e {
                warnings.append("keychain_reset: \\(e)")
            }
        }

        let refreshIDFA = (params["refresh_idfa"] as? Bool) ?? true
        if refreshIDFA {
            do {
                steps.append(["step": "advertising_reset", "result": try AdvertisingTool().invoke(["action": "reset"])])
            } catch let e {
                warnings.append("advertising_reset: \\(e)")
            }
        }

        let name = (params["name"] as? String) ?? "iPhone 16 Pro Max"
        let model = (params["model"] as? String) ?? "iPhone"
        let mi = (params["model_identifier"] as? String) ?? "iPhone17,2"
        let sv = (params["system_version"] as? String) ?? "18.0"

        if let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty {
            do {
                let r = try DeviceFakeTool().invoke([
                    "bundle_id": bundleId,
                    "name": name, "model": model,
                    "model_identifier": mi, "system_version": sv,
                    "mode": "memory"
                ])
                steps.append(["step": "device_fake", "result": r])
            } catch let e {
                warnings.append("device_fake: \\(e)")
            }
        } else {
            let cfg: [String: Any] = [
                "name": name, "model": model,
                "modelIdentifier": mi, "systemVersion": sv
            ]
            let ok = ProcessHelper.writeWorkspaceConfig("fake_device.json", dict: cfg)
            steps.append(["step": "fake_config_written", "result": [
                "written": ok,
                "path": "/var/mobile/Documents/Workspace/fake_device.json",
                "hint": "之后向目标 App 注入 FakeDevice.dylib 即生效"
            ]])
        }

        var result: [String: Any] = ["status": "done", "steps": steps]
        if !warnings.isEmpty { result["warnings"] = warnings }
        result["idfv_note"] = "IDFV 由系统生成不可直接修改；如需完全换新可用 device.refresh_container（重建容器会清掉目标 App 数据，慎用）"
        result["hint"] = "建议重启手机让 keychain 重建彻底生效；伪装效果需目标 App 注入 FakeDevice.dylib 并重启目标 App"
        return result
    }
}
'''

if 'final class NewDeviceTool' not in c:
    c = c.rstrip() + '\n' + tool
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(c)
    print('APPENDED NewDeviceTool')
else:
    print('ALREADY EXISTS')

# ============ MCPCore 注册 ============
path2 = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\MCPCore.swift'
with io.open(path2, 'r', encoding='utf-8') as f:
    c2 = f.read()

old = """        register(RefreshContainerTool())
        register(ContainerWriteTextTool())
        register(ContainerDeleteTool())"""
new = """        register(RefreshContainerTool())
        register(ContainerWriteTextTool())
        register(ContainerDeleteTool())
        // v2.9.99：一键新机（绿盾式组合）
        register(NewDeviceTool())"""
assert old in c2, 'register anchor not found'
c2 = c2.replace(old, new)
with io.open(path2, 'w', encoding='utf-8') as f:
    f.write(c2)
print('REGISTERED NewDeviceTool')
