# -*- coding: utf-8 -*-
import io

path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\ProjectAndTasks.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

# 4. switch 尾部加 5 个 case
old_switch = """                    success = true
                }
            }
        }

        // 生成报告"""
new_switch = """                    success = true
                }
            }

        case .emergencyRecover:
            // 1. 扫描注入/备份状态
            let scanTool = RescueScanTool()
            if let scanResult = try? scanTool.invoke([:]) {
                let injected = scanResult["injected_apps"] as? [[String: Any]] ?? []
                let backups = scanResult["backups"] as? [[String: Any]] ?? []
                steps.append(["step": "扫描注入状态", "success": true,
                              "detail": "注入 \\(injected.count) 个，备份 \\(backups.count) 个"])
            }
            // 2. 恢复全部备份
            let recoverTool = RescueRecoverAllTool()
            if let recoverResult = try? recoverTool.invoke([:]) {
                let restored = recoverResult["restored_count"] as? Int ?? 0
                let failed = recoverResult["failed_count"] as? Int ?? 0
                steps.append(["step": "恢复全部备份", "success": failed == 0,
                              "detail": "恢复 \\(restored) 个，失败 \\(failed) 个"])
                success = failed == 0
            }
            // 3. 验证目标 App 启动
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
            Thread.sleep(forTimeInterval: 4)
            let pid = findPid(by: bundleId)
            steps.append(["step": "验证启动", "success": pid > 0, "detail": pid > 0 ? "PID=\\(pid)" : "未启动"])
            summary = success ? "已恢复全部注入备份，目标 App 可正常启动" : "恢复完成但有失败项，请查看报告"

        case .networkProbe:
            // 1. 停旧抓包
            let capTool = NetworkCaptureTool()
            let _ = try? capTool.invoke(["action": "stop"])
            // 2. 确认 NetworkTweak 已注入
            let injected = (InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false
            if !injected {
                let dylib = ProcessHelper.tweakPath("NetworkTweak.dylib") ?? ""
                if dylib.isEmpty {
                    return TemplateResult(success: false, summary: "内置 NetworkTweak.dylib 不存在", steps: [], reportPath: nil, durationMs: 0)
                }
                let r = try? InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
                if (r?["status"] as? String) != "injected" {
                    return TemplateResult(success: false, summary: "NetworkTweak 注入失败", steps: [], reportPath: nil, durationMs: 0)
                }
            }
            steps.append(["step": "NetworkTweak 就绪", "success": true])
            // 3. 开始抓包
            let startResult = try? capTool.invoke(["action": "start", "bundle_id": bundleId])
            steps.append(["step": "开始抓包", "success": startResult != nil])
            // 4. 打开 App 并等待采集
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
            let waitSec = (options["duration"] as? Int) ?? 8
            Thread.sleep(forTimeInterval: TimeInterval(waitSec))
            // 5. 停止
            let _ = try? capTool.invoke(["action": "stop"])
            // 6. 请求列表
            let limit = (options["limit"] as? Int) ?? 50
            var reqCount = 0
            if let listResult = try? capTool.invoke(["action": "requests", "limit": limit]) {
                let reqs = listResult["requests"] as? [[String: Any]] ?? []
                reqCount = reqs.count
                steps.append(["step": "请求列表", "success": true, "detail": "捕获 \\(reqCount) 条"])
            }
            // 7. 统计分析
            if let anaResult = try? capTool.invoke(["action": "analyze"]) {
                steps.append(["step": "统计分析", "success": true, "detail": "完成"])
                summary = "抓包完成：\\(reqCount) 条请求。\\n" + ((anaResult["summary"] as? String) ?? "")
                success = reqCount > 0
            }

        case .newDevice:
            let ndTool = NewDeviceTool()
            if let result = try? ndTool.invoke(options) {
                steps.append(["step": "一键新机", "success": (result["status"] as? String) == "done",
                              "detail": "见 steps"])
                summary = "已执行：keychain 重置 + 广告符刷新 + 伪装写入" + (((result["warnings"] as? [String])?.isEmpty) == false ? "（部分步骤有警告，见报告）" : "")
                success = true
            } else {
                summary = "一键新机执行失败"
            }

        case .aiAnalyze:
            let aiTool = AiAnalyzeTool()
            var opts = options
            if opts["bundle_id"] == nil { opts["bundle_id"] = bundleId }
            if let result = try? aiTool.invoke(opts) {
                let st = result["status"] as? String ?? ""
                steps.append(["step": "AI 分析", "success": st == "analyzed_and_applied",
                              "detail": (result["ai_output"] as? String ?? "").prefix(120).description])
                summary = (result["applied"] as? [String: Any])?["note"] as? String ?? "已生成 hook 方案并应用"
                success = st == "analyzed_and_applied"
            } else {
                summary = "AI 分析执行失败（检查模型配置）"
            }

        case .crashTriage:
            // 1. 启动诊断（自动拉起 App 判断是否闪退）
            let startupTool = DiagnoseStartupTool()
            var startedOK = false
            if let sr = try? startupTool.invoke(["bundle_id": bundleId]) {
                startedOK = (sr["started"] as? Bool) ?? false
                steps.append(["step": "启动诊断", "success": startedOK,
                              "detail": startedOK ? "可正常启动" : "启动失败/闪退"])
            }
            // 2. 崩溃分析
            let crashTool = DiagnoseCrashTool()
            if let cr = try? crashTool.invoke(["bundle_id": bundleId]) {
                let analyses = cr["analyses"] as? [[String: Any]] ?? []
                if let first = analyses.first {
                    let cause = first["root_cause"] as? String ?? "未知"
                    let fix = first["fix"] as? String ?? ""
                    steps.append(["step": "崩溃分析", "success": true, "detail": cause])
                    summary = "原因：\\(cause)\\n修复建议：\\(fix)"
                    success = !startedOK
                } else {
                    steps.append(["step": "崩溃分析", "success": false, "detail": "未找到崩溃日志"])
                    summary = startedOK ? "App 启动正常，无崩溃记录" : "启动失败但未找到崩溃日志（可能是注入导致，试 emergency_recover）"
                    success = startedOK
                }
            }
            // 3. 采集日志兜底
            let logTool = LogCollectTool()
            if let lr = try? logTool.invoke(["bundle_id": bundleId, "type": "all"]) {
                steps.append(["step": "日志采集", "success": true, "detail": "收集 \\(lr["count"] ?? 0) 个文件"])
            }
        }

        // 生成报告"""
assert c.count(old_switch) == 1, 'switch anchor'
c = c.replace(old_switch, new_switch, 1)

# 5. TaskTool summary + parameters + options 透传
old_task_summary = """        summary: "执行任务模板。把常见流程固化成一键执行：诊断注入失败、采集崩溃现场、注入验证闭环（含自动回滚）、IPA健康检查、性能回归。AI 无需逐步调用工具。",
        parameters: [
            "template": "模板ID：diagnose_injection、capture_crash、inject_verify、ipa_health、perf_regression",
            "bundle_id": "目标 App Bundle ID（不填则用当前项目）",
            "dylib_path": "dylib 路径（inject_verify 时必填）"
        ]"""
new_task_summary = """        summary: "执行任务模板。把常见流程固化成一键执行：诊断注入失败、采集崩溃现场、注入验证闭环（含自动回滚）、IPA健康检查、性能回归、紧急恢复、抓包分析、一键新机、AI分析、闪退诊断。AI 无需逐步调用工具。",
        parameters: [
            "template": "模板ID：diagnose_injection、capture_crash、inject_verify、ipa_health、perf_regression、emergency_recover、network_probe、new_device、ai_analyze、crash_triage",
            "bundle_id": "目标 App Bundle ID（不填则用当前项目）",
            "dylib_path": "dylib 路径（inject_verify 时必填）",
            "options": "模板参数（JSON）：network_probe 的 duration/limit、new_device 的 reset_keychain/refresh_idfa/name/model_identifier、ai_analyze 的 direction/custom_hint/max_classes/prefix"
        ]"""
assert c.count(old_task_summary) == 1, 'task summary anchor'
c = c.replace(old_task_summary, new_task_summary, 1)

old_invoke = """        let dylibPath = params["dylib_path"] as? String ?? ProjectContext.shared.currentProject?.dylibPath

        let result = TaskTemplateRunner.shared.run(type, bundleId: bundleId, dylibPath: dylibPath)"""
new_invoke = """        let dylibPath = params["dylib_path"] as? String ?? ProjectContext.shared.currentProject?.dylibPath
        var options: [String: Any] = [:]
        if let optStr = params["options"] as? String, !optStr.isEmpty,
           let data = optStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            options = obj
        } else if let dict = params["options"] as? [String: Any] {
            options = dict
        }

        let result = TaskTemplateRunner.shared.run(type, bundleId: bundleId, dylibPath: dylibPath, options: options)"""
assert c.count(old_invoke) == 1, 'invoke anchor'
c = c.replace(old_invoke, new_invoke, 1)

with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('PART2 OK (switch/tasktool)')
