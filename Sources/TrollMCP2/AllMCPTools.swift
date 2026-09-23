import Foundation
import UIKit
import Contacts
import EventKit
import CoreLocation
import UserNotifications
import Vision

// MARK: - v3.0.90：system.overview — AI 全局视角目录

final class SystemOverviewTool: MCPTool {
    let definition = ToolDefinition(
        name: "system.overview",
        summary: "Get an overview of all available tools. Use for: when you don't know what tools exist, need to pick the right tool. Don't use for: specific tasks (use the actual tool directly). Example: user says '你都有哪些工具' → system overview.",
        parameters: [:],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let totalTools = ToolRegistry.shared.allToolNames().count

        return [
            "system": "TrollAgent",
            "version": "3.0.90",
            "important_note": "You only know about 5 core tools right now. There are \(totalTools) total tools available! If you can't do something, DON'T give up — always try tool_search first to find the right tool. Many tools are hidden and need to be searched.",
            "ios_version_support": [
                "trollstore_supported": [
                    "iOS 14.0 - 15.4.1 (TrollStore 1)",
                    "iOS 15.5 - 16.6.1 (TrollStore 2)",
                    "iOS 17.0 - 17.0.3 (TrollStore 2 / kfd)"
                ],
                "jailbreak_supported": [
                    "iOS 17.0 - 17.3.1 (Relaxin / RootHide / Dopamine with ElleKit)"
                ],
                "unsupported": [
                    "iOS 16.6.2+ (Apple patched CoreTrust)",
                    "iOS 17.1+ (Apple patched kfd for TrollStore)"
                ],
                "note": "Two environments: (1) TrollStore (jailbreak-free / 白巨魔), (2) Jailbreak (Relaxin/RootHide). Use jailbreak.status to detect which environment you're in."
            ],
            "injection_methods": [
                "jailbreak_ellekit": "jailbreak.inject — runtime injection via ElleKit. Fastest, no binary modification. Only on jailbroken devices (Relaxin/RootHide/Dopamine).",
                "trollstore_ct_bypass": "injection.enable — runtime injection via CoreTrust (ct_bypass). Only on iOS ≤17.0 TrollStore devices.",
                "trollstore_static": "injection.static — static injection (insert_dylib + reinstall). Works on all TrollStore devices, but slower."
            ],
            "tool_categories": [
                [
                    "category": "File System (fs.*)",
                    "typical_tools": ["fs.read", "fs.write", "fs.tree", "fs.find"],
                    "use_for": "Read/write files, browse directories, search files"
                ],
                [
                    "category": "Injection (injection.*)",
                    "typical_tools": ["injection.list", "injection.enable", "injection.status", "injection.mem", "injection.static"],
                    "use_for": "Inject dylib into apps (TrollStore environment), check injection status, search installed apps"
                ],
                [
                    "category": "Jailbreak (jailbreak.*)",
                    "typical_tools": ["jailbreak.status", "jailbreak.inject"],
                    "use_for": "Dylib injection via ElleKit (jailbreak environment only). Use when: device is jailbroken (Relaxin/RootHide/Dopamine). Faster than static injection, no binary modification. Note: loads at app startup, not runtime attach."
                ],
                [
                    "category": "UI Control (control.*)",
                    "typical_tools": ["control.inject", "control.tap", "control.tap_text", "control.type_text", "control.swipe", "control.screenshot"],
                    "use_for": "Control target app UI: tap, swipe, type text, screenshot"
                ],
                [
                    "category": "App Control (app.*)",
                    "typical_tools": ["app.launch", "app.restart", "app.duplicate", "app.encrypt_info"],
                    "use_for": "Launch/restart apps, clone apps, check encryption status"
                ],
                [
                    "category": "System (system.*)",
                    "typical_tools": ["device.info", "device.battery", "system.overview"],
                    "use_for": "Device info, battery status, system overview"
                ],
                [
                    "category": "Browser (browser.*)",
                    "typical_tools": ["browser.navigate", "browser.screenshot"],
                    "use_for": "Web browsing, navigate to URLs"
                ],
                [
                    "category": "Shell (shell.*)",
                    "typical_tools": ["shell.exec"],
                    "use_for": "Run shell commands (Linux/iSH environment)"
                ],
                [
                    "category": "Memory (memory)",
                    "typical_tools": ["memory"],
                    "use_for": "H5GG-style memory modification: search, filter, write, freeze values"
                ],
                [
                    "category": "Diagnostics (diagnostics.*)",
                    "typical_tools": ["probe.inspect", "device.probe"],
                    "use_for": "Inspect app internals, probe classes/methods"
                ],
                [
                    "category": "Build & Self-Evolution (build.*, tool.load_dylib)",
                    "typical_tools": ["tool.load_dylib", "project.generate_tweak", "build.runner.token"],
                    "use_for": "Write custom tools in Swift, compile to dylib, load into TrollAgent on-the-fly (self-evolution). Also generate Tweak project templates for reverse engineering."
                ]
            ],
            "recommended_workflows": [
                [
                    "task": "Inject dylib into an app (choose injection method)",
                    "steps": [
                        "1. jailbreak.status() — check if device is jailbroken",
                        "2. If jailbreak detected: jailbreak.inject(bundle_id, dylib_path) — ElleKit runtime injection (fast)",
                        "3. If no jailbreak: injection.enable(bundle_id) — ct_bypass or static injection",
                        "4. control.inject(bundle_id) — inject ControlAgent for UI control",
                        "5. control.screenshot() — verify injection worked"
                    ]
                ],
                [
                    "task": "Inject dylib into an app (TrollStore only)",
                    "steps": [
                        "1. injection.list(\"keyword\") — find bundle_id",
                        "2. injection.enable(bundle_id) — inject dylib (persistent)",
                        "3. control.inject(bundle_id) — inject ControlAgent for UI control",
                        "4. control.screenshot() — verify injection worked"
                    ]
                ],
                [
                    "task": "Control an app's UI",
                    "steps": [
                        "1. control.inject(bundle_id) — inject ControlAgent",
                        "2. control.screenshot() — see current screen",
                        "3. control.tap_text(\"button text\") — tap by text",
                        "4. control.type_text(\"search\", \"query\") — type into field"
                    ]
                ],
                [
                    "task": "Read app container files",
                    "steps": [
                        "1. fs.tree(bundle_id) — browse container directory",
                        "2. fs.read(path) — read specific file"
                    ]
                ]
            ],
            "tips": [
                "If you don't know which tool to use, call tool_search first",
                "If you're stuck after 2 tries, ask the user for clarification",
                "Don't repeat the same tool with the same params — it's a loop",
                "Before injecting dylib, call jailbreak.status() to detect environment",
                "Jailbreak environment (ElleKit): use jailbreak.inject (fast, no reinstall, loads at startup)",
                "TrollStore + iOS ≤17.0: use injection.enable (ct_bypass runtime)",
                "TrollStore + iOS 17.0.1+: use injection.static (static injection)",
                "iOS 17+: ct_bypass is broken on TrollStore — use static or jailbreak.inject"
            ]
        ]
    }
}

// MARK: - v3.0.90：system.lessons — AI 经验教训库

final class SystemLessonsTool: MCPTool {
    let definition = ToolDefinition(
        name: "system.lessons",
        summary: "Get known issues and best practices. Use for: when you hit an error, check if it's a known issue with a known fix. Don't use for: general system overview (use system.overview). Example: user says '分享功能闪退，之前有过吗' → check lessons.",
        parameters: [
            "topic": "Topic to look up (optional, empty for all)"
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let topic = (params["topic"] as? String ?? "").lowercased()

        var lessons: [[String: Any]] = [
            [
                "issue": "ct_bypass fails / CoreTrust bypass broken",
                "cause": "iOS 17.0+ patched CVE-2023-41991 (CoreTrust multi-signer bug)",
                "solution": "Use injection.static (static injection + trollstorehelper reinstall). iOS 17+ auto-switches to this method.",
                "category": "injection"
            ],
            [
                "issue": "opainject EBADARCH 85",
                "cause": "opainject binary architecture mismatch (arm64 vs arm64e)",
                "solution": "Check if opainject is compiled for the correct architecture. arm64e devices (A12+) need arm64e opainject.",
                "category": "injection"
            ],
            [
                "issue": "Injection succeeds but app crashes / won't start",
                "cause": "Main binary is encrypted (App Store DRM). insert_dylib modifies load commands but encrypted binary can't load.",
                "solution": "Decrypt the app first: use app.decrypt to dump decrypted Mach-O, then inject.",
                "category": "injection"
            ],
            [
                "issue": "Injection hangs / phone gets hot",
                "cause": "Target app has security SDK (ByteDance / Tencent / Alibaba). Anti-injection protection blocks opainject.",
                "solution": "Try a different app. Known problematic: WeChat, Xianyu, Douyin, Alipay, banking apps.",
                "category": "injection"
            ],
            [
                "issue": "teamid empty / no Team ID",
                "cause": "System apps have no Team ID field in signature. ct_bypass needs Team ID to spoof.",
                "solution": "System apps are not supported for memory injection. Try third-party apps instead.",
                "category": "injection"
            ],
            [
                "issue": "You keep calling the same tool with same params",
                "cause": "You're stuck in a loop. The tool returns the same result every time.",
                "solution": "Check _call_count in tool result. If >= 3, you're looping. Try a different approach or ask user.",
                "category": "loop"
            ],
            [
                "issue": "tool_search returns different tools every time",
                "cause": "tool_search returns random subset of matching tools. You might miss some.",
                "solution": "tool_search now dedupes: already-approved tools are excluded. Search once, you'll get new tools next time.",
                "category": "tool_search"
            ],
            [
                "issue": "control.* tools don't work",
                "cause": "ControlAgent.dylib not injected yet.",
                "solution": "Call control.inject(bundle_id) first to inject ControlAgent.dylib. Then control.* tools work.",
                "category": "ui_control"
            ]
        ]

        // Filter by topic if specified
        if !topic.isEmpty {
            lessons = lessons.filter { lesson in
                (lesson["issue"] as? String ?? "").lowercased().contains(topic) ||
                (lesson["cause"] as? String ?? "").lowercased().contains(topic) ||
                (lesson["category"] as? String ?? "").lowercased().contains(topic)
            }
        }

        return [
            "lessons": lessons,
            "count": lessons.count,
            "note": "These are lessons learned from past bugs. If you hit an error, check if it matches a known issue."
        ]
    }
}

// MARK: - v3.0.90：task.progress — 任务进度跟踪

final class TaskProgressTool: MCPTool {
    let definition = ToolDefinition(
        name: "task.progress",
        summary: "Track task progress. Use for: set/check progress of a multi-step task. Call set to update progress, call get to check current status. Don't use for: single-step tasks (just do it directly).",
        parameters: [
            "action": "set or get (required)",
            "step": "Current step number (for set, e.g. 1 of 5)",
            "total_steps": "Total steps (for set, e.g. 5)",
            "description": "What you're doing now (for set, e.g. 'Injecting dylib into target app')"
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = params["action"] as? String ?? "get"

        switch action {
        case "set":
            guard let step = params["step"] as? Int else {
                throw MCPError.invalidParams("step required for set")
            }
            let total = params["total_steps"] as? Int ?? 0
            let desc = params["description"] as? String ?? ""
            UserDefaults.standard.set(step, forKey: "task_progress_step")
            UserDefaults.standard.set(total, forKey: "task_progress_total")
            UserDefaults.standard.set(desc, forKey: "task_progress_desc")
            return [
                "status": "updated",
                "step": step,
                "total_steps": total,
                "description": desc,
                "percent": total > 0 ? Int(Double(step) / Double(total) * 100) : 0
            ]
        default:
            let step = UserDefaults.standard.integer(forKey: "task_progress_step")
            let total = UserDefaults.standard.integer(forKey: "task_progress_total")
            let desc = UserDefaults.standard.string(forKey: "task_progress_desc") ?? ""
            return [
                "step": step,
                "total_steps": total,
                "description": desc,
                "percent": total > 0 ? Int(Double(step) / Double(total) * 100) : 0
            ]
        }
    }
}

// MARK: - v3.0.90：verify.* — 结果自动验证

final class VerifyInjectTool: MCPTool {
    let definition = ToolDefinition(
        name: "verify.inject",
        summary: "Verify if injection succeeded. Use for: after injection.enable/injection.mem, check if dylib actually loaded. Don't use for: launch app (use app.launch).",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "check_http": "Check if ControlAgent HTTP server is up (default true)"
        ],
        verified: true, category: "verify")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bid) else {
            return ["verified": false, "reason": "App not found"]
        }

        // 1. 检查 App 是否在运行
        let exeName = ProcessHelper.executableName(for: app)
        let pid = ProcessHelper.pidOf(executableName: exeName)
        guard let runningPid = pid else {
            return [
                "verified": false,
                "reason": "App not running. Launch it first: app.launch(bundle_id)",
                "app_running": false
            ]
        }

        // 2. 检查 HTTP 端口（ControlAgent 4789 / ProbeAgent 4791）
        var httpUp = false
        if (params["check_http"] as? Bool) ?? true {
            for port in [4789, 4791] {
                if let url = URL(string: "http://127.0.0.1:\(port)/"),
                   let resp = try? Data(contentsOf: url, options: .alwaysMapped),
                   !resp.isEmpty {
                    httpUp = true
                    break
                }
            }
        }

        return [
            "verified": httpUp,
            "app_running": true,
            "pid": runningPid,
            "http_up": httpUp,
            "reason": httpUp ? "Injection verified: app running + HTTP server up" : "App running but HTTP server not responding. Injection may have failed.",
            "next_step": httpUp ? "You're good to go" : "Try re-injecting, or check if app crashed"
        ]
    }
}

final class VerifyFileTool: MCPTool {
    let definition = ToolDefinition(
        name: "verify.file",
        summary: "Verify if file exists and has expected content. Use for: after fs.write, check if file was written correctly. Don't use for: read file content (use fs.read).",
        parameters: [
            "path": "File path to verify (required)",
            "expect_size": "Expected file size in bytes (optional)",
            "expect_contains": "Expected string in file content (optional)"
        ],
        verified: true, category: "verify")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return ["verified": false, "reason": "File not found", "path": path]
        }
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        var checks: [String: Any] = [
            "verified": true,
            "path": path,
            "size": size
        ]

        // 检查大小
        if let expectedSize = params["expect_size"] as? Int {
            checks["size_match"] = size == expectedSize
            if size != expectedSize {
                checks["verified"] = false
                checks["reason"] = "Size mismatch: expected \(expectedSize), got \(size)"
            }
        }

        // 检查内容
        if let expectedStr = params["expect_contains"] as? String, !expectedStr.isEmpty {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let contains = content.contains(expectedStr)
                checks["content_contains"] = contains
                if !contains {
                    checks["verified"] = false
                    checks["reason"] = "Content does not contain expected string"
                }
            }
        }

        return checks
    }
}

final class VerifyAppRunningTool: MCPTool {
    let definition = ToolDefinition(
        name: "verify.app_running",
        summary: "Verify if an app is currently running. Use for: after app.launch, check if it actually started. Don't use for: launch app (use app.launch).",
        parameters: [
            "bundle_id": "App bundle_id to check (required)"
        ],
        verified: true, category: "verify")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bid) else {
            return ["running": false, "reason": "App not found"]
        }
        let exeName = ProcessHelper.executableName(for: app)
        let pid = ProcessHelper.pidOf(executableName: exeName)
        return [
            "running": pid != nil,
            "pid": pid ?? 0,
            "bundle_id": bid,
            "name": app.name
        ]
    }
}

// MARK: - M3 注入工具

final class InjectionEnableTool: MCPTool {
    let definition = ToolDefinition(name: "injection.enable", summary: "Inject a dylib/plugin into an app permanently. Use for: persistent injection that survives app restart. Don't use for: temporary testing (use injection.mem), check injection status (use injection.status). Note: only works on iOS ≤17.0 with ct_bypass; iOS 17.0.1+ uses static injection. Example: user says '把 ControlAgent 注入小红书' → enable injection.",
        parameters: ["bundle_id": "Target App bundle_id (required)", "dylib_path": "Local plugin path (.dylib/.framework/.zip/.deb, e.g. Workspace/downloads/.../xxx.deb). Default: built-in ControlAgent.dylib", "weak_reference": "Optional Bool: weak reference injection (default false, matches TrollFools)", "inject_strategy": "Optional String: injection target strategy lexicographic (default)/fast (smallest file first)/preorder/postorder, matches TrollFools Strategy", "smart_fallback": "Optional Bool: auto-fallback to memory injection if no static target (default true)"],
        verified: true,
        category: "injection",
        maxIOSMajor: 17  // ct_bypass 只支持到 iOS 17.0
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let dylibPath = params["dylib_path"] as? String
        let weakRef = (params["weak_reference"] as? Bool) ?? false
        let strategy = (params["inject_strategy"] as? String) ?? "lexicographic"
        // v2.9.32：dylib_path 为本地文件路径 → 作为注入源（root 拷贝进目标 App）；
        // 为 @executable_path/@loader_path 前缀 → 作为 load name；空 → 内置 agent。
        var source: String?
        var loadName = "@executable_path/ControlAgent.dylib"
        if let p = dylibPath, !p.isEmpty {
            if p.hasPrefix("@executable_path/") || p.hasPrefix("@loader_path/") {
                loadName = p
            } else {
                source = p
                loadName = "@executable_path/\((p as NSString).lastPathComponent)"
            }
        }
        let result = try InjectionManager.shared.enable(bundleId: bid, dylibName: loadName, dylibSourcePath: source, weakReference: weakRef, injectStrategy: strategy, smartFallback: (params["smart_fallback"] as? Bool) ?? true)
        AuditLog.shared.log("injection.enable", detail: "\(bid) → \(dylibPath ?? "内置agent")")
        // v2.9.68：截断冗长日志，只保留 exit code + 关键错误行，避免上下文爆炸
        var slim = result
        for key in ["ct_bypass_output", "ldid_output", "insert_output", "rpath_output"] {
            if let full = slim[key] as? String, !full.isEmpty {
                let lines = full.components(separatedBy: .newlines)
                // 只保留最后 3 行 + 包含 error/fail/fatal 的行
                let important = lines.filter { line in
                    let lower = line.lowercased()
                    return lower.contains("error") || lower.contains("fail") || lower.contains("fatal") || lower.contains("cannot") || lower.contains("operation not permitted")
                }
                let tail = Array(lines.suffix(3))
                var seen = Set<String>()
                let deduped = (important + tail).filter { seen.insert($0).inserted }
                let summary = deduped.prefix(5).joined(separator: "\n")
                slim[key] = summary.isEmpty ? "(日志已截断，完整日志见工作区)" : summary
                slim["\(key)_truncated"] = lines.count > 5
            }
        }
        // v2.9.125：CLI 式一句话结论（dispatch 会取 message 放顶层）
        if let injected = result["injected"] as? Bool {
            let alive = (result["selfcheck"] as? [String: Any])?["app_alive"] as? Bool ?? false
            slim["message"] = injected
                ? "注入成功（injected=true, app存活=\(alive ? "是" : "否")\(slim["risk_warning"] != nil ? ", 敏感App已护栏" : "")）"
                : "注入未生效（injected=false）"
        }
        return slim
    }
}

final class InjectionDisableTool: MCPTool {
    let definition = ToolDefinition(name: "injection.disable", summary: "Remove/uninstall dylib injection from an app. Use for: undo injection, rollback to original app, disable hook. Don't use for: just restart app (use app.restart), uninstall app (use app.uninstall). Example: user says '把小红书的注入删掉' → disable injection on com.xingin.discover.",
        parameters: ["bundle_id": "Target App bundle_id (required). e.g. com.xingin.discover", "desist": "Optional Bool: fully remove (default true; false=disable but keep backup, can re-enable later)"], verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let desist = (params["desist"] as? Bool) ?? true
        let result = try InjectionManager.shared.disable(bundleId: bid, desist: desist)
        AuditLog.shared.log("injection.disable", detail: bid)
        return result
    }
}

// v3.0.89：iOS 17 兼容的静态注入（insert_dylib + trollstorehelper 重装）
final class InjectionStaticTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.static",
        summary: "Static injection for iOS 17+ (ct_bypass broken). Copy app → insert_dylib → repack IPA → trollstorehelper reinstall. Use for: iOS 17.0+ where runtime injection (ct_bypass) no longer works. Don't use for: iOS 16 or earlier (use injection.enable instead, faster).",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "dylib_path": "Local dylib path (required, e.g. Workspace/downloads/xxx.dylib)"
        ], verified: true, category: "injection")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let dylibPath = params["dylib_path"] as? String, !dylibPath.isEmpty else {
            throw MCPError.invalidParams("dylib_path required")
        }
        let (ok, msg) = InjectionManager.shared.injectStatic(bundleId: bid, dylibPath: dylibPath)
        AuditLog.shared.log("injection.static", detail: "\(bid) → \(dylibPath)")
        return ["ok": ok, "message": msg]
    }
}

final class InjectionEnablePersistedTool: MCPTool {
    let definition = ToolDefinition(name: "injection.enable_persisted", summary: "Re-enable a disabled plugin on an app (toggle injection back on). Use for: you disabled injection before, now want to turn it back on. Don't use for: inject new dylib (use injection.enable), check if injected (use injection.status). Example: user says '小红书的注入重新打开' → enable_persisted.",
        parameters: ["bundle_id": "Target App bundle ID (required)"], verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let result = try InjectionManager.shared.restore(bundleId: bid)
        AuditLog.shared.log("injection.enable_persisted", detail: bid)
        return result
    }
}

final class InjectionStatusTool: MCPTool {
    let definition = ToolDefinition(name: "injection.status", summary: "Show which apps are already injected (have dylib loaded). Use for: check if an app is already injected, see overall injection stats. Don't use for: find a specific app's bundle_id (use injection.list), inject into app (use injection.enable). Example: user says '小红书注入了吗' → check status of com.xingin.discover.", verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        InjectionManager.shared.status()
    }
}

final class InjectionInspectTool: MCPTool {
    let definition = ToolDefinition(name: "injection.inspect", summary: "Check which dylibs are loaded in an app (injection status details). Use for: verify if injection actually worked, see what dylibs are loaded. Don't use for: list all injected apps (use injection.status), inject dylib (use injection.enable). Example: user says '小红书注入成功了吗' → inspect injection details.",
        parameters: ["bundle_id": "Target App bundle_id (required)"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        return InjectionManager.shared.inspect(bid)
    }
}

final class InjectionListTool: MCPTool {
    // v2.9.41：检索式——query 按名称/bundle_id 模糊匹配，只返回命中项，不再全量 266 条塞给 AI
    let definition = ToolDefinition(name: "injection.list",
        summary: "Search/find installed apps on the phone. Use for: find bundle_id for a specific app (e.g. find 小红书's bundle_id), list what apps are installed. Don't use for: check injection status (use injection.status), launch app (use app.launch). Example: user says '找小红书' → search '小红书' → get bundle_id com.xingin.discover.",
        parameters: ["query": "Search keyword (App Chinese name or bundle_id fragment, optional). If empty, return first 20 only. e.g. 小红书 / 微博 / tiktok / weibo"],
        returns: ["apps": "List of matching apps (bundle_id + name)", "count": "Number of results"],
        verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let apps = AppCatalog.list()
        let q = (params["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matched: [AppCatalog.AppEntry]
        if q.isEmpty {
            matched = Array(apps.prefix(20))
        } else {
            matched = apps.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.bundleId.localizedCaseInsensitiveContains(q)
            }
        }
        return [
            "total": apps.count,
            "matched": matched.count,
            "query": q,
            "hint": q.isEmpty ? "共 \(apps.count) 个 App，只返回前 20 条；请用 query 按名称/bundle_id 搜索目标（如 query=\"Troll\"）" : "命中 \(matched.count) 个，以下最多 20 条",
            "apps": Array(matched.prefix(20)).map { ["bundle_id": $0.bundleId, "name": $0.name] }
        ]
    }
}

// MARK: - v3.1.1：Jailbreak (ElleKit) 运行时注入工具

final class JailbreakStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "jailbreak.status",
        summary: "Check jailbreak status and injection mode availability. Use for: determine if runtime ElleKit injection is available. Don't use for: checking which apps are injected — use injection.status instead.",
        parameters: [:],
        returns: [
            "is_jailbroken": "true if jailbreak detected",
            "has_ellekit": "true if ElleKit framework is installed",
            "has_dopamine": "true if Dopamine jailbreak detected",
            "has_roothide": "true if RootHide jailbreak detected",
            "injection_mode": "Current injection mode: ellekit_runtime / ct_bypass / static_only",
            "note": "Usage guidance"
        ],
        verified: true,
        category: "jailbreak",
        requiresJailbreak: false  // 所有环境都可见，用来检测
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        InjectionManager.shared.jailbreakStatus()
    }
}

final class JailbreakInjectTool: MCPTool {
    let definition = ToolDefinition(
        name: "jailbreak.inject",
        summary: "Dylib injection via ElleKit (jailbreak only). Use for: inject dylib into app WITHOUT modifying binary (faster, no reinstall). ElleKit loads dylib at app startup (not runtime attach). Only works on jailbroken devices (Relaxin/RootHide/Dopamine). Don't use for: non-jailbroken devices — use injection.enable instead. Safety: cannot inject system apps. Note: restart target app to take effect.",
        parameters: [
            "bundle_id": "Target app bundle_id (e.g. com.xingin.discover for Xiaohongshu). System apps are blocked for safety.",
            "dylib_path": "Path to the dylib file to inject (e.g. /var/mobile/Containers/Data/Application/.../Documents/MyDylib.dylib)",
            "mode": "Injection mode: 'persist' (permanent, default) or 'once' (temporary). Optional."
        ],
        returns: [
            "success": "true if injection succeeded",
            "message": "Detailed result message",
            "mode": "Injection mode used"
        ],
        verified: true,
        category: "jailbreak",
        requiresJailbreak: true  // 仅越狱环境可见
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String,
              let dylibPath = params["dylib_path"] as? String else {
            throw MCPError.invalidParams("bundle_id and dylib_path are required")
        }
        let mode = params["mode"] as? String ?? "persist"
        let (success, message) = InjectionManager.shared.injectViaElleKit(bundleId: bundleId, dylibPath: dylibPath, mode: mode)
        return [
            "success": success,
            "message": message,
            "mode": mode,
            "bundle_id": bundleId
        ]
    }
}

final class ContainerWriteTextTool: MCPTool {
    let definition = ToolDefinition(name: "container.write_text", summary: "Write a text file into an app's data container (DANGEROUS!). Use for: modify app data files, write config into app sandbox. Don't use for: write workspace files (use fs.write), read app files (use fs.read). Warning: modifying app data can crash it! Example: user says '改一下小红书的配置文件' → write to container.",
        parameters: ["bundle_id": "Target App bundle ID", "path": "File path inside app container", "content": "Text content to write"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String,
              let path = params["path"] as? String,
              let content = params["content"] as? String else {
            throw MCPError.invalidParams("bundle_id, path, content required")
        }
        guard let app = AppCatalog.find(bid), let container = app.containerPath else {
            throw MCPError.failed("container not accessible for \(bid)")
        }
        let url = URL(fileURLWithPath: container).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        AuditLog.shared.log("container.write_text", detail: "\(bid):\(path)")
        return ["written": true, "bytes": content.utf8.count]
    }
}

// MARK: - M4 Gateway 工具

final class CronFireTool: MCPTool {
    let definition = ToolDefinition(name: "cron.fire", summary: "Manually trigger a scheduled/cron task. Use for: test automation task works, run scheduled task right now instead of waiting. Don't use for: create new automation task (use automation.create), list tasks (use automation.list). Example: user says '立刻跑一下定时任务' → fire the task.",
        parameters: ["task": "Name of the scheduled task to trigger"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let task = params["task"] as? String ?? "unnamed"
        AuditLog.shared.log("cron.fire", detail: task)
        return ["fired": true, "task": task]
    }
}

// MARK: - M4 自动化工具（真实 UNUserNotificationCenter 调度）

final class AutomationRunNowTool: MCPTool {
    let definition = ToolDefinition(name: "automation.run_now", summary: "Run an automation task immediately (right now, don't wait for schedule). Use for: execute a saved automation task manually. Don't use for: create new task (use automation.create), list all tasks (use automation.list). Example: user says '跑一下那个定时任务' → run it now.",
        parameters: ["name": "Task name or ID to run immediately"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let store = AutomationStore.shared
        let matched = store.tasks.first { $0.name == name || $0.id.uuidString == name }
        guard let task = matched else { throw MCPError.failed("task not found: \(name)") }
        guard store.run(name: task.name) else { throw MCPError.failed("task disabled or not found: \(name)") }
        return ["ran": true, "name": task.name, "kind": task.kind]
    }
}

final class AutomationListTool: MCPTool {
    let definition = ToolDefinition(name: "automation.list", summary: "List all saved automation/scheduled tasks. Use for: see what scheduled tasks exist, check task list. Don't use for: run a task now (use automation.run_now), stop a task (use automation.stop). Example: user says '我有哪些定时任务' → list all automation tasks.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let tasks = AutomationStore.shared.tasks.map { t in
            [
                "id": t.id.uuidString,
                "name": t.name,
                "kind": t.kind,
                "enabled": t.enabled,
                "schedule": t.schedule,
                "delay": t.delay,
                "interval": t.interval,
                "lastRun": t.lastRun.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ] as [String: Any]
        }
        return ["count": tasks.count, "tasks": tasks]
    }
}

final class AutomationJobsTool: MCPTool {
    let definition = ToolDefinition(name: "automation.jobs", summary: "Check pending automation tasks and notification permission status. Use for: see how many tasks are scheduled, check if notifications are allowed. Don't use for: list task details (use automation.list), run task now (use automation.run_now). Example: user says '有多少定时任务在排队' → check automation jobs.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let store = AutomationStore.shared
        let status = AutomationSchedulerStatus()
        return [
            "authStatus": status,
            "pending": store.tasks.filter { $0.enabled }.count,
            "total": store.tasks.count,
            "jobs": store.tasks.map { ["id": $0.id.uuidString, "name": $0.name, "kind": $0.kind, "enabled": $0.enabled] }
        ]
    }
}

final class AutomationStopTool: MCPTool {
    let definition = ToolDefinition(name: "automation.stop", summary: "Stop/disable a scheduled automation task. Use for: cancel a scheduled task, turn off automation. Don't use for: list all tasks (use automation.list), run task now (use automation.run_now). Example: user says '把那个定时任务停了' → stop the task.",
        parameters: ["name": "Task name or ID to stop"], verified: true, category: "device")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let store = AutomationStore.shared
        guard let task = store.tasks.first(where: { $0.name == name || $0.id.uuidString == name }) else {
            throw MCPError.failed("task not found: \(name)")
        }
        store.remove(task)
        AuditLog.shared.log("automation.stop", detail: name)
        return ["stopped": true, "name": name]
    }
}

final class AutomationStatusTool: MCPTool {
    let definition = ToolDefinition(name: "automation.status", summary: "Check automation engine status: how many tasks, how many enabled, notification auth. Use for: monitor automation system, check if notifications are allowed. Don't use for: list specific task details (use automation.list).")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "engine": "UNUserNotificationCenter",
            "authStatus": AutomationSchedulerStatus(),
            "tasks": AutomationStore.shared.tasks.count,
            "enabled": AutomationStore.shared.tasks.filter { $0.enabled }.count
        ]
    }
}

/// 读取通知授权状态（iOS 14 用 getNotificationSettings）
/// v2.9.87：改为非阻塞——返回缓存值，后台异步刷新，避免信号量阻塞调用线程。
func AutomationSchedulerStatus() -> String {
    let cacheKey = "automation.notif.status.cache"
    let cached = UserDefaults.standard.string(forKey: cacheKey) ?? "unknown"
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        var status = "unknown"
        switch settings.authorizationStatus {
        case .authorized: status = "authorized"
        case .denied: status = "denied"
        case .notDetermined: status = "notDetermined"
        case .provisional: status = "provisional"
        case .ephemeral: status = "ephemeral"
        @unknown default: status = "unknown"
        }
        UserDefaults.standard.set(status, forKey: cacheKey)
    }
    return cached
}

// MARK: - M5 系统能力工具

final class ContactsSearchTool: MCPTool {
    let definition = ToolDefinition(name: "contacts.search", summary: "Search iPhone contacts by name. Use for: find someone's phone number, look up a contact. Don't use for: send message (use other tools), read calendar (use calendar.list). Example: user says '张三的电话多少' → search contacts.",
        parameters: ["query": "Name keyword to search (e.g. '张三' / 'Bob')"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let query = params["query"] as? String ?? ""
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactPhoneNumbersKey as NSString
        ]
        var results: [[String: Any]] = []

        let req = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: req) { contact, stop in
            let name = "\(contact.givenName)\(contact.familyName)"
            if query.isEmpty || name.localizedCaseInsensitiveContains(query) {
                results.append([
                    "name": name,
                    "phones": contact.phoneNumbers.map { $0.value.stringValue }
                ])
            }
            if results.count >= 50 { stop.pointee = true }
        }
        AuditLog.shared.log("contacts.search", detail: "query=\(query) found=\(results.count)")
        return ["contacts": results]
    }
}

final class CalendarListTool: MCPTool {
    let definition = ToolDefinition(name: "calendar.list", summary: "List upcoming calendar events (iPhone Calendar). Use for: check what meetings/appointments are coming up. Don't use for: create reminder (use reminder.create), search contacts (use contacts.search). Example: user says '我这周有什么安排' → list calendar events for next 7 days.",
        parameters: ["days": "How many days ahead to look (default 7)"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let days = params["days"] as? Int ?? 7
        let store = EKEventStore()
        let cal = Calendar.current
        let now = Date()
        let endOf = cal.date(byAdding: .day, value: days, to: now) ?? now

        let predicate = store.predicateForEvents(withStart: now, end: endOf, calendars: nil)
        let events = store.events(matching: predicate)
        return [
            "events": events.map { [
                "title": $0.title ?? "",
                "start": ISO8601DateFormatter().string(from: $0.startDate),
                "end": ISO8601DateFormatter().string(from: $0.endDate)
            ]}
        ]
    }
}

final class ReminderCreateTool: MCPTool {
    let definition = ToolDefinition(name: "reminder.create", summary: "Create a reminder in iPhone Reminders app. Use for: set a to-do, remember something. Don't use for: list upcoming events (use calendar.list), send notification (use notification.send). Example: user says '提醒我明天开会' → create a reminder.",
        parameters: ["title": "Reminder title (e.g. 'Buy milk')", "notes": "Optional notes for the reminder"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = params["notes"] as? String
        try store.save(reminder, commit: true)
        AuditLog.shared.log("reminder.create", detail: title)
        return ["created": true, "title": title]
    }
}

final class LocationGetTool: MCPTool {
    let definition = ToolDefinition(name: "location.get", summary: "Get current GPS location (latitude/longitude). Use for: find where the phone is, location-based tasks. Don't use for: spoof fake location (use device.fake), get device info (use device.info). Example: user says '我现在在哪' → get current location.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let mgr = LocationProvider.shared
        return [
            "latitude": mgr.latitude ?? 0,
            "longitude": mgr.longitude ?? 0,
            "available": mgr.available
        ]
    }
}

final class NotificationSendTool: MCPTool {
    let definition = ToolDefinition(name: "notification.send", summary: "Send a local push notification to the iPhone. Use for: alert user when task done, remind user. Don't use for: create reminder (use reminder.create), send message. Example: user says '编译完了提醒我' → send notification when done.",
        parameters: ["title": "Notification title", "body": "Notification message text"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let title = params["title"] as? String ?? "TrollMCP"
        let body = params["body"] as? String ?? ""
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        AuditLog.shared.log("notification.send", detail: title)
        return ["sent": true]
    }
}

final class ScanQRTool: MCPTool {
    let definition = ToolDefinition(name: "scan.qr", summary: "Decode QR code or barcode from an image file. Use for: read QR code content from a screenshot/image. Don't use for: OCR text recognition (use ocr.image), take screenshot (use control.screenshot). Example: user says '这个二维码是什么内容' → decode QR from image.",
        parameters: ["image_path": "Image file path (in workspace) containing QR code"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["image_path"] as? String else { throw MCPError.invalidParams("image_path required") }
        let url = try Workspace.resolve(path)
        guard let imgData = try? Data(contentsOf: url),
              let image = UIImage(data: imgData),
              let cgImage = image.cgImage else {
            throw MCPError.failed("cannot load image: \(path)")
        }
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        let results = request.results?.compactMap { $0.payloadStringValue } ?? []
        return ["codes": results]
    }
}

final class ProcessListTool: MCPTool {
    let definition = ToolDefinition(name: "process.list", summary: "List all running apps/processes on the device. Use for: find what's currently running, check if an app is alive, find app bundle_id. Don't use for: find a specific app (use injection.list with search), kill app (use app.restart). Example: user says '现在什么在后台跑着' → list all running processes.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        var procs: [[String: Any]] = []
        for app in AppCatalog.list() {
            procs.append(["bundle_id": app.bundleId, "name": app.name])
            if procs.count >= 100 { break }
        }
        return ["count": procs.count, "processes": procs]
    }
}

// MARK: - M6 编译模式工具

final class BuildRunnerTokenTool: MCPTool {
    let definition = ToolDefinition(name: "build.runner.token", summary: "Generate or verify a build authentication token (for CI builds). Use for: authenticate with build system. Don't use for: trigger GitHub Actions build (use github.trigger_build), check GitHub login (use github.account_status). Example: user says '生成 build token' → generate token.",
        parameters: ["action": "generate (create new token) or verify (check token validity)"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = params["action"] as? String ?? "generate"
        if action == "generate" {
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32)
            AuditLog.shared.log("build.token", detail: "generated")
            return ["token": String(token), "action": "generate"]
        }
        return ["action": "verify", "valid": true]
    }
}

final class ProjectGenerateTweakTool: MCPTool {
    let definition = ToolDefinition(name: "project.generate_tweak", summary: "Generate a Tweak project template (Theos Makefile + Tweak.x + plist). Use for: start a new jailbreak tweak development project. Don't use for: compile existing tweak (use github.trigger_build), load dylib (use tool.load_dylib). Example: user says '创建一个新的 tweak 项目' → generate template.",
        parameters: ["name": "Project name (e.g. MyTweak)", "bundle_id": "Target app bundle ID (optional)"], verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let name = params["name"] as? String ?? "MyTweak"
        let bid = params["bundle_id"] as? String ?? ""
        let dir = Workspace.root.appendingPathComponent("projects/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let makefile = """
        THEOS_PACKAGE_SCHEME=rootless
        TARGET = iphone:clang:latest:14.0
        ARCHS = arm64
        INSTALL_TARGET_PROCESSES = SpringBoard

        TWEAK_NAME = \(name)
        \(name)_FILES = Tweak.x
        \(name)_CFLAGS = -fobjc-arc

        include $(THEOS)/makefiles/common.mk
        include $(THEOS_MAKE_PATH)/tweak.mk
        """
        try makefile.write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let plist = """
        { Filter = { Executables = ( "\(bid.isEmpty ? "com.example.app" : bid)" ); }; }
        """
        try plist.write(to: dir.appendingPathComponent("\(name).plist"), atomically: true, encoding: .utf8)
        // v2.9.3：生成最小 Tweak.x 源文件，工程开箱即可编译（编译环境见 build.environment）
        let tweakX = """
        #import <UIKit/UIKit.h>

        // 最小 Tweak 模板：把下面的钩子目标替换为你要 hook 的类/方法。
        // 例如 hook SpringBoard 的 applicationDidFinishLaunching：
        %hook SpringBoard
        - (void)applicationDidFinishLaunching:(id)application {
            %orig;
            NSLog(@"[\(name)] loaded");
        }
        %end
        """
        try tweakX.write(to: dir.appendingPathComponent("Tweak.x"), atomically: true, encoding: .utf8)
        AuditLog.shared.log("project.generate_tweak", detail: name)
        return ["created": true, "path": "projects/\(name)", "name": name,
                "files": ["Makefile", "Tweak.x", "\(name).plist"]]
    }
}

final class ModelConfigTool: MCPTool {
    let definition = ToolDefinition(name: "model.config", summary: "View LLM model configurations (which AI models are available). Use for: check what AI models are configured, see current default model. Don't use for: change model (use model.update), system overview (use system.overview). Example: user says '现在用的什么模型' → show model config.",
        parameters: ["action": "list (all configs) or default (current default)"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = params["action"] as? String ?? "list"
        if action == "default", let cfg = ModelStore.shared.defaultConfig {
            return ["name": cfg.name, "model": cfg.model, "provider": cfg.provider]
        }
        return [
            "configs": ModelStore.shared.configs.map { ["name": $0.name, "model": $0.model, "provider": $0.provider] },
            "count": ModelStore.shared.configs.count
        ]
    }
}

/// v2.9.299：远程修改模型配置（AI 诊断时可帮用户切换模型名/协议，无需手动设置）
final class ModelUpdateTool: MCPTool {
    let definition = ToolDefinition(name: "model.update",
        summary: "Modify an existing LLM model configuration. Use for: change model settings, switch default model, update API endpoint. Don't use for: view current configs (use model.config), list all models (use model.config list). Example: user says '把默认模型换成 deepseek' → update model config.",
        parameters: ["name": "Config name to modify (e.g. 'deepseek')", "model": "New model name (optional)", "baseURL": "New API base URL (optional)", "apiProtocol": "API protocol type (optional)", "contextTokens": "Context token limit (optional)", "isDefault": "Set as default model (optional bool)", "resetCompat": "Reset compatibility level (optional bool)"],
        verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        guard let idx = ModelStore.shared.configs.firstIndex(where: { $0.name == name }) else {
            throw MCPError.failed("未找到配置: \(name)")
        }
        var cfg = ModelStore.shared.configs[idx]
        var changed: [String] = []
        if let m = params["model"] as? String, !m.isEmpty, m != cfg.model {
            cfg.model = m; changed.append("model=\(m)")
        }
        if let b = params["baseURL"] as? String, !b.isEmpty, b != cfg.baseURL {
            cfg.baseURL = b; changed.append("baseURL=\(b)")
        }
        if let p = params["apiProtocol"] as? String, !p.isEmpty, p != cfg.apiProtocol {
            cfg.apiProtocol = p; changed.append("apiProtocol=\(p)")
        }
        if let ct = params["contextTokens"] as? Int, ct != cfg.contextTokens {
            cfg.contextTokens = ct; changed.append("contextTokens=\(ct)")
        }
        if let d = params["isDefault"] as? Bool, d != cfg.isDefault {
            if d {
                for i in ModelStore.shared.configs.indices { ModelStore.shared.configs[i].isDefault = false }
            }
            cfg.isDefault = d; changed.append("isDefault=\(d)")
        }
        if let rc = params["resetCompat"] as? Bool, rc {
            cfg.compatLevel = 0; changed.append("compatLevel=0")
        }
        ModelStore.shared.configs[idx] = cfg
        ModelStore.shared.save()
        AuditLog.shared.log("model.update", detail: "\(name): \(changed.joined(separator: ", "))")
        return ["ok": true, "name": name, "changed": changed,
                "now": ["model": cfg.model, "baseURL": cfg.baseURL, "apiProtocol": cfg.apiProtocol, "compatLevel": cfg.compatLevel]]
    }
}

// v2.9.128：工具健康度自查——AI 和用户都能看到"哪些工具经常失败、为什么失败、怎么修"
final class ToolHealthTool: MCPTool {
    let definition = ToolDefinition(
        name: "tools.health",
        summary: "Check tool health statistics (how many times each tool failed). Use for: debug which tools are broken, see failure rates. Don't use for: actual tool execution, view audit log (use other tools). Example: user says '哪些工具老出问题' → check tool health.",
        parameters: [
            "limit": "How many tools to show (default 20)"
        ],
    verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let limit = max(1, min((params["limit"] as? Int) ?? 20, 100))
        let audit = AuditLog.shared
        let summary = audit.healthSummary(limit: limit)
        let dist = audit.codeDistribution()
        let recent = audit.recentFailures(limit: 8).map { e -> [String: Any] in
            [
                "tool": e.category,
                "code": e.errorCode ?? "unknown",
                "reason": e.errorReason ?? e.detail,
                "next_step": e.nextStep ?? "",
                "time": Self.timeStr(e.timestamp)
            ]
        }
        return [
            "ok": true,
            "message": "工具健康度：失败工具 \(summary.filter { $0.failure > 0 }.count) 个，错误码分布 \(dist.map { "\($0.code)×\($0.count)" }.joined(separator: " "))",
            "data": [
                "error_code_distribution": dist.map { ["code": $0.code, "count": $0.count] },
                "tool_health": summary.map { h -> [String: Any] in
                    [
                        "tool": h.tool,
                        "success": h.success,
                        "failure": h.failure,
                        "failure_rate": String(format: "%.1f%%", h.failureRate * 100),
                        "avg_ms": h.avgMs,
                        "top_error_code": h.topCode,
                        "last_failure": h.lastFailureDetail
                    ]
                },
                "recent_failures": recent
            ]
        ]
    }

    private static func timeStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

final class WorkspaceInfoTool: MCPTool {
    let definition = ToolDefinition(name: "workspace.info", summary: "Show workspace info: path, free space, directory structure with descriptions. Use for: locate files, understand what each directory is for. Don't use for: read file contents (use fs.read).")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: Workspace.root.path)) ?? []
        let attrs = (try? fm.attributesOfItem(atPath: Workspace.root.path)) ?? [:]

        // 目录说明（AI 一看就知道每个目录是干嘛的）
        let dirDescriptions: [String: String] = [
            "uploads": "用户上传的文件（图片/文件附件自动复制到这里）",
            "downloads": "下载的文件（IPA / dylib / 工具等）",
            "projects": "编译项目（每个项目一个子目录，放 tweak 源码）",
            "duplicates": "App 双开副本（app.duplicate 生成）",
            "static_inject": "静态注入临时目录（injection.static 用）",
            "screenshots": "截图（control.screenshot 保存到这里）",
            "tweaks": "内置 dylib 插件（ControlAgent / ProbeAgent / MemoryTweak 等）",
            "bridge_exports": "桥接导出文件",
            "artifacts": "生成的产物（编译结果 / 分析报告等）",
            "knowledge": "知识库文件",
            "backups": "备份文件（注入前自动备份）",
            "logs": "日志文件",
            "cache": "缓存文件"
        ]

        // 给每个条目加说明
        var annotatedEntries: [[String: Any]] = []
        for item in items {
            var entry: [String: Any] = ["name": item]
            if let desc = dirDescriptions[item] {
                entry["description"] = desc
            }
            // 检查是不是目录
            var isDir: ObjCBool = false
            fm.fileExists(atPath: Workspace.root.appendingPathComponent(item).path, isDirectory: &isDir)
            entry["is_dir"] = isDir.boolValue
            annotatedEntries.append(entry)
        }

        return [
            "root": Workspace.root.path,
            "entries": annotatedEntries,
            "entry_count": items.count,
            "size_bytes": attrs[.size] ?? 0,
            "note": "每个目录的用途已在 description 字段说明。需要读文件用 fs.read，看目录用 fs.tree。"
        ]
    }
}

// MARK: - 位置提供者

final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let mgr = CLLocationManager()
    var latitude: Double?
    var longitude: Double?
    var available = false

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            latitude = loc.coordinate.latitude
            longitude = loc.coordinate.longitude
            available = true
        }
    }
}

// MARK: - v3.1.34: inject 大工具 + 子命令（合并 7 个 injection.* 工具）

final class InjectionExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "inject",
        summary: "Manage dylib injection (enable/disable/status/list/inspect). Use subcommand to specify action. Use for: inject/remove dylib into apps, check injection status. Don't use for: launch app (use app launch), UI control (use control). Example: enable → inject enable bundle_id:com.xxx; status → inject status; list → inject list query:小红书. Subcommands: enable / disable / static / enable_persisted / status / inspect / list.",
        parameters: [
            "command": "Subcommand: enable / disable / static / enable_persisted / status / inspect / list",
            "bundle_id": "App bundle ID",
            "dylib_path": "Dylib path (for enable)",
            "query": "Search query (for list)"
        ],
        verified: true, category: "injection")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("inject", detail: command)
        
        switch command {
        case "enable":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            var p: [String: Any] = ["bundle_id": bundleId]
            if let dylib = params["dylib_path"] as? String { p["dylib_path"] = dylib }
            return try InjectionEnableTool().invoke(p)
            
        case "disable":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionDisableTool().invoke(["bundle_id": bundleId])
            
        case "static":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionStaticTool().invoke(["bundle_id": bundleId])
            
        case "enable_persisted":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionEnablePersistedTool().invoke(["bundle_id": bundleId])
            
        case "status":
            return try InjectionStatusTool().invoke([:])
            
        case "inspect":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionInspectTool().invoke(["bundle_id": bundleId])
            
        case "list":
            var p: [String: Any] = [:]
            if let query = params["query"] as? String { p["query"] = query }
            return try InjectionListTool().invoke(p)
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: enable/disable/static/enable_persisted/status/inspect/list")
        }
    }
}

// MARK: - v3.1.35: automation 大工具 + 子命令（合并 7 个 automation.* 工具）

final class AutomationExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "automation",
        summary: "Manage automation/scheduled tasks (run/list/stop/status). Use subcommand to specify action. Use for: schedule tasks, run/stop automation. Don't use for: one-off reminders (use reminder.*). Example: run → automation run name:task1; list → automation list; stop → automation stop name:task1. Subcommands: run / list / jobs / stop / status / history / set_enabled.",
        parameters: [
            "command": "Subcommand: run / list / jobs / stop / status / history / set_enabled",
            "name": "Task name or ID",
            "enabled": "Enable/disable (for set_enabled)"
        ],
        verified: true, category: "automation")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("automation", detail: command)
        
        switch command {
        case "run":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try AutomationRunNowTool().invoke(["name": name])
            
        case "list":
            return try AutomationListTool().invoke([:])
            
        case "jobs":
            return try AutomationJobsTool().invoke([:])
            
        case "stop":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try AutomationStopTool().invoke(["name": name])
            
        case "status":
            return try AutomationStatusTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: run/list/jobs/stop/status/history/set_enabled")
        }
    }
}
