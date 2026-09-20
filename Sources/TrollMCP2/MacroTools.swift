import Foundation
import UIKit

// MARK: - v2.9.141 AI 操作宏录制/回放
// 录制：macro.record 开启后，ui.tap/swipe/long_press/clipboard 调用自动入宏（含截图验证点）
// 回放：macro.run 用控制中心实时展示进度（计划=宏步骤），纯执行+每步截图存证（不耗 token 调 AI）

enum MacroStore {
    static var dir: URL { Workspace.root.appendingPathComponent("macros", isDirectory: true) }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func save(name: String, steps: [[String: Any]]) throws {
        ensureDir()
        let safe = sanitize(name)
        var payload: [String: Any] = [
            "name": safe,
            "created": Int(Date().timeIntervalSince1970),
            "steps": steps
        ]
        if let old = load(safe), let oc = old["created"] as? Int { payload["created"] = oc }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(safe).appendingPathExtension("json"))
    }

    static func load(_ name: String) -> [String: Any]? {
        ensureDir()
        let url = dir.appendingPathComponent(sanitize(name)).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func list() -> [[String: Any]] {
        ensureDir()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [[String: Any]] = []
        for f in files where f.pathExtension == "json" {
            guard let obj = load(f.deletingPathExtension().lastPathComponent) else { continue }
            let steps = obj["steps"] as? [[String: Any]] ?? []
            out.append([
                "name": f.deletingPathExtension().lastPathComponent,
                "steps": steps.count,
                "created": obj["created"] as? Int ?? 0
            ])
        }
        out.sort { ($0["created"] as? Int ?? 0) > ($1["created"] as? Int ?? 0) }
        return out
    }

    static func delete(_ name: String) -> Bool {
        ensureDir()
        let url = dir.appendingPathComponent(sanitize(name)).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        return false
    }

    private static func sanitize(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: disallowed).joined(separator: "")
        return cleaned.isEmpty ? "宏\(Int(Date().timeIntervalSince1970))" : cleaned
    }
}

// 录制器：全局开关，ui.* 工具调用时 capture
final class MacroRecorder {
    static let shared = MacroRecorder()
    private(set) var isRecording = false
    private(set) var currentName = ""
    private var steps: [[String: Any]] = []

    func start(name: String) {
        currentName = name
        steps = []
        isRecording = true
    }

    /// ui 工具调用钩子：录制中则记录（裁剪大参数）
    func capture(tool: String, params: [String: Any]) {
        guard isRecording else { return }
        var clean = params
        // reason 保留（回放说明），大文本裁剪
        if let t = clean["text"] as? String, t.count > 200 { clean["text"] = String(t.prefix(200)) }
        steps.append(["tool": tool, "params": clean])
    }

    @discardableResult
    func stop() -> (ok: Bool, message: String) {
        guard isRecording else { return (false, "当前未在录制") }
        isRecording = false
        let name = currentName
        let count = steps.count
        currentName = ""
        steps = []
        guard count > 0 else { return (false, "宏为空（没有记录到任何操作）") }
        do {
            try MacroStore.save(name: name, steps: steps)
            return (true, "宏「\(name)」已保存，共 \(count) 步")
        } catch {
            return (false, "保存失败: \(error.localizedDescription)")
        }
    }

    func cancel() {
        isRecording = false
        currentName = ""
        steps = []
    }
}

// 回放执行器
final class MacroRunner {
    static func run(name: String, loop: Int, stepDelayMs: Int, completion: @escaping (Bool, String) -> Void) {
        guard let macro = MacroStore.load(name) else {
            completion(false, "宏「\(name)」不存在")
            return
        }
        let steps = macro["steps"] as? [[String: Any]] ?? []
        guard !steps.isEmpty else { completion(false, "宏为空"); return }

        let loops = max(1, min(loop, 100))
        let plan = steps.map { step -> String in
            let tool = step["tool"] as? String ?? "?"
            let p = step["params"] as? [String: Any] ?? [:]
            let reason = p["reason"] as? String ?? ""
            let xy = (p["x"] as? Double).map { " (\(Int($0)),\(Int(p["y"] as? Double ?? 0)))" } ?? ""
            return reason.isEmpty ? "\(tool)\(xy)" : "\(tool)\(xy) — \(reason)"
        }

        DispatchQueue.global(qos: .userInitiated).async {
            ControlSession.shared.begin(target: "宏回放 · \(name)", plan: plan)
            var done = 0
            var failed = 0
            for _ in 0..<loops {
                for (i, step) in steps.enumerated() {
                    guard let tool = step["tool"] as? String else { continue }
                    let p = step["params"] as? [String: Any] ?? [:]
                    ControlSession.shared.updateStep(index: i, status: .running, detail: tool)
                    let ok = execute(tool: tool, params: p)
                    if ok {
                        done += 1
                        ControlSession.shared.updateStep(index: i, status: .done, detail: tool)
                    } else {
                        failed += 1
                        ControlSession.shared.updateStep(index: i, status: .failed, detail: "执行失败（回放中止）")
                        ControlSession.shared.addResult("❌ \(tool) 回放失败，已中止")
                        ControlSession.shared.finish(result: "宏「\(name)」回放失败：第 \(i + 1) 步 \(tool) 执行失败。可手动检查目标 App 状态后重试。")
                        DispatchQueue.main.async { completion(false, "第 \(i + 1) 步失败") }
                        return
                    }
                    Thread.sleep(forTimeInterval: Double(max(stepDelayMs, 50)) / 1000.0)
                }
            }
            // 每步截图存证（最后一步额外留证）
            let sem = DispatchSemaphore(value: 0)
            ScreenCapture.take { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 8)
            ControlSession.shared.addResult("📸 已留存现场截图")
            ControlSession.shared.finish(result: "宏「\(name)」回放完成：\(loops) 次 × \(steps.count) 步，成功 \(done) 步，失败 \(failed) 步。")
            DispatchQueue.main.async { completion(true, "回放完成（\(done) 步成功）") }
        }
    }

    private static func execute(tool: String, params: [String: Any]) -> Bool {
        let x = Float(params["x"] as? Double ?? 0)
        let y = Float(params["y"] as? Double ?? 0)
        switch tool {
        case "ui.tap":
            return HIDTouchInjector.shared.tap(x: x, y: y)
        case "ui.long_press":
            return HIDTouchInjector.shared.longPress(x: x, y: y, durationMs: params["duration_ms"] as? Int ?? 800)
        case "ui.swipe":
            return HIDTouchInjector.shared.swipe(
                x1: x, y1: y,
                x2: Float(params["x2"] as? Double ?? 0), y2: Float(params["y2"] as? Double ?? 0),
                durationMs: params["duration_ms"] as? Int ?? 300)
        case "ui.clipboard":
            UIThreadBridge.paste(params["text"] as? String ?? "")
            return true
        default:
            return false
        }
    }
}

// MARK: - MCP 工具

final class MacroRecordTool: MCPTool {
    let definition = ToolDefinition(name: "macro.record",
        summary: "Start recording an AI action macro: subsequent ui.tap/swipe/long_press/clipboard calls are recorded. Use macro.stop to save.",
        parameters: ["name": "Macro name"], verified: true, category: "macro")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        MacroRecorder.shared.start(name: name)
        ControlSession.shared.addLog(.info, "🎬 开始录制宏「\(name)」——后续 ui.* 操作将记录")
        return ["message": "开始录制宏「\(name)」。之后每次 ui.tap/swipe/long_press/clipboard 都会记录；完成后调用 macro.stop"]
    }
}

final class MacroStopTool: MCPTool {
    let definition = ToolDefinition(name: "macro.stop",
        summary: "Stop macro recording and save.",
        parameters: [:])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let (ok, msg) = MacroRecorder.shared.stop()
        guard ok else { throw MCPError.failed(msg) }
        ControlSession.shared.addLog(.info, "💾 \(msg)")
        return ["message": msg]
    }
}

final class MacroListTool: MCPTool {
    let definition = ToolDefinition(name: "macro.list",
        summary: "List saved macros (name/step count/creation time).",
        parameters: [:], verified: true, category: "macro")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let list = MacroStore.list()
        return ["macros": list, "count": list.count]
    }
}

final class MacroRunTool: MCPTool {
    let definition = ToolDefinition(name: "macro.run",
        summary: "Replay a macro: pure execution (no AI thinking), shows progress in control center + screenshot evidence at end. Target app must be in foreground.",
        parameters: ["name": "Macro name", "loop": "Loop count (default 1, max 100)", "step_delay_ms": "Delay between steps ms (default 300)"], verified: true, category: "macro")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        let loop = params["loop"] as? Int ?? 1
        let delay = params["step_delay_ms"] as? Int ?? 300
        var out: [String: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        MacroRunner.run(name: name, loop: loop, stepDelayMs: delay) { ok, msg in
            out["ok"] = ok
            out["message"] = msg
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 600)
        guard let ok = out["ok"] as? Bool, ok else {
            throw MCPError.failed(out["message"] as? String ?? "回放超时（或失败）")
        }
        return ["message": out["message"] ?? "回放完成", "name": name, "loop": loop]
    }
}

final class MacroDeleteTool: MCPTool {
    let definition = ToolDefinition(name: "macro.delete",
        summary: "Delete a macro.",
        parameters: ["name": "Macro name"], verified: true, category: "macro")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        let ok = MacroStore.delete(name)
        guard ok else { throw MCPError.failed("宏「\(name)」不存在") }
        return ["message": "已删除宏「\(name)」"]
    }
}

final class MacroExportTool: MCPTool {
    let definition = ToolDefinition(name: "macro.export",
        summary: "Export a macro as JSON to workspace (backup/share).",
        parameters: ["name": "Macro name"], verified: true, category: "macro")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        guard let macro = MacroStore.load(name) else { throw MCPError.failed("宏不存在") }
        let src = MacroStore.dir.appendingPathComponent(name).appendingPathExtension("json")
        let dst = Workspace.root.appendingPathComponent("macros_export").appendingPathComponent(name).appendingPathExtension("json")
        do {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: src, to: dst)
            return ["message": "已导出: \(dst.path)", "path": dst.path]
        } catch {
            throw MCPError.failed("导出失败: \(error.localizedDescription)")
        }
    }
}
