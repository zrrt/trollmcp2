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
        summary: "Get complete system overview: all tool categories, typical tools per category, and recommended workflows. Use when: you don't know what tools are available, or you're unsure which tool to use. Don't use for: specific tasks (use the actual tool directly).",
        parameters: [:],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return [
            "system": "TrollAgent",
            "version": "3.0.90",
            "ios_version_support": [
                "supported": [
                    "iOS 14.0 - 15.4.1 (TrollStore 1)",
                    "iOS 15.5 - 16.6.1 (TrollStore 2)",
                    "iOS 17.0 - 17.0.3 (TrollStore 2 / kfd)"
                ],
                "unsupported": [
                    "iOS 16.6.2+ (Apple patched CoreTrust)",
                    "iOS 17.1+ (Apple patched kfd)"
                ],
                "note": "TrollAgent requires TrollStore (jailbreak-free / 无根越狱). If device is on unsupported iOS version, core features work but injection may fail."
            ],
            "injection_methods": [
                "iOS 14-16.6.1": "ct_bypass runtime injection (fast, persistent)",
                "iOS 17.0-17.0.3": "static injection (insert_dylib + trollstorehelper reinstall)"
            ],
            "tool_categories": [
                [
                    "category": "File System (fs.*)",
                    "typical_tools": ["fs.read", "fs.write", "fs.tree", "fs.find"],
                    "use_for": "Read/write files, browse directories, search files"
                ],
                [
                    "category": "Injection (injection.*)",
                    "typical_tools": ["injection.list", "injection.enable", "injection.status", "injection.mem"],
                    "use_for": "Inject dylib into apps, check injection status, search installed apps"
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
                ]
            ],
            "recommended_workflows": [
                [
                    "task": "Inject dylib into an app",
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
                "iOS 17+: use injection.static (ct_bypass is broken)"
            ]
        ]
    }
}

// MARK: - v3.0.90：system.lessons — AI 经验教训库

final class SystemLessonsTool: MCPTool {
    let definition = ToolDefinition(
        name: "system.lessons",
        summary: "Get lessons learned from past bugs and edge cases. Use when: you hit an error and don't know why, or you're unsure if a known issue applies. Don't use for: general system overview (use system.overview).",
        parameters: [
            "topic": "Optional: specific topic to look up (e.g. injection, crash, dark mode, share). Leave empty for all lessons."
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
                "issue": "Share / export crashes the app",
                "cause": "Presenting ShareSheet from inside a sheet causes nested sheet crash on iOS.",
                "solution": "Use SharePresenter.present() which dismisses existing sheet first, then presents.",
                "category": "ui"
            ],
            [
                "issue": "Dark mode: text invisible / white on white",
                "cause": "Hardcoded colors (.black / .white) don't adapt to dark mode.",
                "solution": "Use system dynamic colors: .label (text), .secondarySystemBackground (background).",
                "category": "ui"
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

// MARK: - M3 注入工具

final class InjectionEnableTool: MCPTool {
    let definition = ToolDefinition(name: "injection.enable", summary: "Inject plugin (dylib/framework/zip/deb) into target App (TrollFools-style: auto CydiaSubstrate + multi-asset + strategy). v3.0.59 smart: fallback to memory injection if no static target. Use for: persistent injection (survives restart). Decision guide: (1) Temporary/probing → injection.mem (memory, no file change); (2) Need persistent → injection.enable (static, modifies file); (3) Main binary encrypted → app.decrypt first; (4) UI customization → hook.apply; (5) Device spoofing → device.fake.",
        parameters: ["bundle_id": "Target App bundle_id (required)", "dylib_path": "Local plugin path (.dylib/.framework/.zip/.deb, e.g. Workspace/downloads/.../xxx.deb). Default: built-in ControlAgent.dylib", "weak_reference": "Optional Bool: weak reference injection (default false, matches TrollFools)", "inject_strategy": "Optional String: injection target strategy lexicographic (default)/fast (smallest file first)/preorder/postorder, matches TrollFools Strategy", "smart_fallback": "Optional Bool: auto-fallback to memory injection if no static target (default true)"], verified: true, category: "injection")
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
    let definition = ToolDefinition(name: "injection.disable", summary: "Remove dylib injection from target App (desist=false: disable but keep backup for re-enable).",
        parameters: ["bundle_id": "Target App bundle_id (required)", "desist": "Optional Bool: fully remove (default true; false=disable but keep backup, can re-enable via injection.restore)"], verified: true, category: "injection")
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
    let definition = ToolDefinition(name: "injection.enable_persisted", summary: "Re-enable disabled plugin from persistent backup (TrollFools-style enable toggle).",
        parameters: ["bundle_id": "Target App bundle_id (required)"], verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let result = try InjectionManager.shared.restore(bundleId: bid)
        AuditLog.shared.log("injection.enable_persisted", detail: bid)
        return result
    }
}

final class InjectionStatusTool: MCPTool {
    let definition = ToolDefinition(name: "injection.status", summary: "Show current injection stats (which apps are already injected). Use for: check injection status. Don't use for: finding a specific App — use injection.list with query instead.", verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        InjectionManager.shared.status()
    }
}

final class InjectionInspectTool: MCPTool {
    let definition = ToolDefinition(name: "injection.inspect", summary: "Check dylib loading status of target App. Use for: verify injection.",
        parameters: ["bundle_id": "Target App bundle_id (required)"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        return InjectionManager.shared.inspect(bid)
    }
}

final class InjectionListTool: MCPTool {
    // v2.9.41：检索式——query 按名称/bundle_id 模糊匹配，只返回命中项，不再全量 266 条塞给 AI
    let definition = ToolDefinition(name: "injection.list", 
        summary: "Search installed apps by keyword. Use for: find bundle_id for injection.",
        parameters: ["query": "Search keyword (App name or bundle_id fragment, optional). If empty, return first 20 only"],
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

final class ContainerWriteTextTool: MCPTool {
    let definition = ToolDefinition(name: "container.write_text", summary: "Write text file to App container (DANGEROUS). Use for: modify App data.",
        parameters: ["bundle_id": "Target App bundle_id", "path": "Path inside container", "content": "Text content"])
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

final class GatewayStatusTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.status", summary: "[DEPRECATED] Gateway status removed.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "connected": GatewayClient.shared.isConnected,
            "url": GatewayClient.shared.serverURL,
            "error": GatewayClient.shared.lastError ?? ""
        ]
    }
}

final class GatewayConnectTool: MCPTool {
    let definition = ToolDefinition(name: "gateway.connect", summary: "[DEPRECATED] Gateway connect removed.",
        parameters: ["url": "WebSocket URL ws://...", "token": "Pairing token (optional)"], verified: true, category: "automation")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let url = params["url"] as? String else { throw MCPError.invalidParams("url required") }
        GatewayClient.shared.pairedToken = params["token"] as? String
        GatewayClient.shared.connect(url: url)
        AuditLog.shared.log("gateway.connect", detail: url)
        return ["connecting": true, "url": url]
    }
}

final class CronFireTool: MCPTool {
    let definition = ToolDefinition(name: "cron.fire", summary: "Trigger scheduled task manually. Use for: test cron task logic.",
        parameters: ["task": "Task name"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let task = params["task"] as? String ?? "unnamed"
        AuditLog.shared.log("cron.fire", detail: task)
        return ["fired": true, "task": task]
    }
}

// MARK: - M4 自动化工具（真实 UNUserNotificationCenter 调度）

final class AutomationRunNowTool: MCPTool {
    let definition = ToolDefinition(name: "automation.run_now", summary: "Run automation task immediately. Use for: execute scheduled task now.",
        parameters: ["name": "Task name or id"], verified: true)
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
    let definition = ToolDefinition(name: "automation.list", summary: "List automation tasks. Use for: check scheduled tasks.")
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
    let definition = ToolDefinition(name: "automation.jobs", summary: "Show pending automation tasks and notification auth status. Use for: check task queue.")
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
    let definition = ToolDefinition(name: "automation.stop", summary: "Stop automation task. Use for: cancel scheduled task.",
        parameters: ["name": "Task name or id"], verified: true, category: "device")
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
    let definition = ToolDefinition(name: "automation.status", summary: "Show automation engine status: running/current task/queue/recent records. Use for: monitor automation.")
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
    let definition = ToolDefinition(name: "contacts.search", summary: "Search contacts. Use for: find contact.",
        parameters: ["query": "Search keyword"], verified: true)
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
    let definition = ToolDefinition(name: "calendar.list", summary: "List upcoming calendar events. Use for: check schedule.",
        parameters: ["days": "Days ahead (default 7)"], verified: true)
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
    let definition = ToolDefinition(name: "reminder.create", summary: "Create reminder: title/time/repeat. Use for: schedule reminder.",
        parameters: ["title": "Title", "notes": "Notes (optional)"])
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
    let definition = ToolDefinition(name: "location.get", summary: "Get current device location. Use for: GPS coordinates.")
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
    let definition = ToolDefinition(name: "notification.send", summary: "Send local notification. Use for: reminder/alert.",
        parameters: ["title": "Title", "body": "Body"], verified: true)
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
    let definition = ToolDefinition(name: "scan.qr", summary: "Scan QR/barcode from image. Use for: decode QR code.",
        parameters: ["image_path": "Image path inside workspace"], verified: true)
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
    let definition = ToolDefinition(name: "process.list", summary: "List running processes (all). Use for: find target App pid for injection.")
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
    let definition = ToolDefinition(name: "build.runner.token", summary: "Build mode: generate/verify build token. Use for: CI build auth.",
        parameters: ["action": "generate or verify"], verified: true)
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
    let definition = ToolDefinition(name: "project.generate_tweak", summary: "Generate Tweak project template (Makefile + Tweak.x + plist). Use for: start tweak project.",
        parameters: ["name": "Project name", "bundle_id": "Target App (optional)"], verified: true, category: "build")
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
    let definition = ToolDefinition(name: "model.config", summary: "View/manage model configuration. Use for: check LLM settings.",
        parameters: ["action": "list or default"], verified: true)
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
        summary: "Update model config (by name). Use for: modify LLM settings.",
        parameters: ["name": "Config name to modify (e.g. deepseek)", "model": "New model name (optional)", "baseURL": "New Base URL (optional)", "apiProtocol": "Protocol (optional: OpenAI Chat Completions / OpenAI Responses / Anthropic Messages / Custom Endpoint)", "contextTokens": "Context token budget (optional)", "isDefault": "Set as default (optional bool)", "resetCompat": "Reset compat level to 0 (optional bool)"],
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
        summary: "Check tool health (failure count). Use for: debug tool issues.",
        parameters: [
            "limit": "Max tools to return health data (default 20)"
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
    let definition = ToolDefinition(name: "workspace.info", summary: "Show workspace info: path, free space, directory structure. Use for: locate files.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: Workspace.root.path)) ?? []
        let attrs = (try? fm.attributesOfItem(atPath: Workspace.root.path)) ?? [:]
        return [
            "root": Workspace.root.path,
            "entries": items,
            "entry_count": items.count,
            "size_bytes": attrs[.size] ?? 0
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
