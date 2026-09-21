import Foundation
import UIKit
import UserNotifications
import CoreMedia
import ReplayKit

// MARK: - v2.9.139 HID 触摸注入（TrollStore 无沙箱 + com.apple.private.hid.client.event-dispatch）
// 原理：IOHIDEventSystemClient 创建 digitizer 触摸事件并分发到系统，
// 可对任意前台 App（美团/小红书等）合成点击/滑动/长按——AI 控制任意 App UI 的关键能力。
// 全部符号用 dlsym 动态加载（私有 API 编译期不可见），云端无法真机验证，按社区通用实现。

final class HIDTouchInjector {
    static let shared = HIDTouchInjector()
    private let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private var client: CFTypeRef?

    // IOHIDEventFieldDigitizer*（Apple 私有头文件常量，越狱社区通用）
    private enum F {
        static let digitizerX: UInt32 = 12
        static let digitizerY: UInt32 = 13
        static let digitizerType: UInt32 = 16
        static let digitizerIndex: UInt32 = 17
        static let digitizerIdentity: UInt32 = 18
        static let digitizerEventMask: UInt32 = 19
        static let digitizerRange: UInt32 = 20
        static let digitizerTouch: UInt32 = 21
        static let digitizerIsDisplayIntegrated: UInt32 = 35
    }
    // kIOHIDEventTypeDigitizer / kIOHIDDigitizerTransducerTypeFinger / event mask
    private enum K {
        static let eventTypeDigitizer: UInt32 = 11
        static let transducerFinger: Int64 = 2
        static let maskRange: Int64 = 0x4
        static let maskTouch: Int64 = 0x8
        static let maskTouching: Int64 = 0x10
    }

    private typealias CreateClientFn = @convention(c) (CFAllocator?) -> CFTypeRef?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias EventCreateFn = @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> CFTypeRef?
    private typealias SetIntFn = @convention(c) (CFTypeRef, UInt32, Int64) -> Void
    private typealias SetFloatFn = @convention(c) (CFTypeRef, UInt32, Float) -> Void
    private typealias SetSenderFn = @convention(c) (CFTypeRef, UInt64) -> Void
    private typealias DispatchFn = @convention(c) (CFTypeRef, CFTypeRef) -> Void
    private typealias ReleaseFn = @convention(c) (CFTypeRef) -> Void

    private func load<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let sym = dlsym(h, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    /// 初始化 HID client（幂等）。失败返回原因（缺权限/符号不可用）。
    @discardableResult
    func ensureClient() -> (ok: Bool, reason: String) {
        if client != nil { return (true, "") }
        guard let create = load("IOHIDEventSystemClientCreate", CreateClientFn.self) else {
            return (false, "IOHIDEventSystemClientCreate 符号不可用（IOKit 未加载）")
        }
        guard let c = create(kCFAllocatorDefault) else {
            return (false, "创建 HID client 失败（需 com.apple.private.hid.client.event-dispatch 权限）")
        }
        client = c
        // 匹配 digitizer 服务（UsagePage=0x0E digitizer, Usage=0x05 touch screen）
        if let setMatching = load("IOHIDEventSystemClientSetMatching", SetMatchingFn.self) {
            let dict = ["DeviceUsagePage": 0x0E, "DeviceUsage": 0x05] as CFDictionary
            setMatching(c, dict)
        }
        return (true, "")
    }

    /// 构造并分发一个 digitizer 触摸事件（mask 控制按下/抬起）
    private func dispatchDigitizer(mask: Int64, x: Float, y: Float) -> Bool {
        let ready = ensureClient()
        guard ready.ok, let c = client else { return false }
        guard let eventCreate = load("IOHIDEventCreate", EventCreateFn.self),
              let setInt = load("IOHIDEventSetIntegerValue", SetIntFn.self),
              let setFloat = load("IOHIDEventSetFloatValue", SetFloatFn.self),
              let dispatch = load("IOHIDEventSystemClientDispatchEvent", DispatchFn.self),
              let release = load("CFRelease", ReleaseFn.self) else { return false }

        let now = UInt64(mach_absolute_time())
        guard let ev = eventCreate(kCFAllocatorDefault, K.eventTypeDigitizer, now, 0) else { return false }
        defer { release(ev) }

        setInt(ev, F.digitizerType, K.transducerFinger)
        setInt(ev, F.digitizerIndex, 0)
        setInt(ev, F.digitizerIdentity, 0)
        setInt(ev, F.digitizerEventMask, mask)
        setInt(ev, F.digitizerRange, 1)
        setInt(ev, F.digitizerTouch, 1)
        setInt(ev, F.digitizerIsDisplayIntegrated, 1)
        setFloat(ev, F.digitizerX, x)
        setFloat(ev, F.digitizerY, y)
        if let setSender = load("IOHIDEventSetSenderID", SetSenderFn.self) {
            setSender(ev, 0x00)
        }
        dispatch(c, ev)
        return true
    }

    private var scale: Float {
        Float(UIScreen.main.scale)
    }

    /// 点击（points 坐标 → 内部转 pixels）
    func tap(x: Float, y: Float) -> Bool {
        let px = x * scale, py = y * scale
        guard dispatchDigitizer(mask: K.maskRange | K.maskTouch | K.maskTouching, x: px, y: py) else { return false }
        Thread.sleep(forTimeInterval: 0.06)
        guard dispatchDigitizer(mask: K.maskRange | K.maskTouch, x: px, y: py) else { return false }
        return true
    }

    /// 长按（durationMs 毫秒）
    func longPress(x: Float, y: Float, durationMs: Int) -> Bool {
        let px = x * scale, py = y * scale
        guard dispatchDigitizer(mask: K.maskRange | K.maskTouch | K.maskTouching, x: px, y: py) else { return false }
        Thread.sleep(forTimeInterval: Double(max(durationMs, 50)) / 1000.0)
        guard dispatchDigitizer(mask: K.maskRange | K.maskTouch, x: px, y: py) else { return false }
        return true
    }

    /// 滑动（从 A 到 B，durationMs 毫秒，插值步进模拟手指轨迹）
    func swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Int) -> Bool {
        let s = scale
        let startX = x1 * s, startY = y1 * s, endX = x2 * s, endY = y2 * s
        guard dispatchDigitizer(mask: K.maskRange | K.maskTouch | K.maskTouching, x: startX, y: startY) else { return false }
        let steps = max(12, min(40, durationMs / 16))
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let cx = startX + (endX - startX) * t
            let cy = startY + (endY - startY) * t
            dispatchDigitizer(mask: K.maskRange | K.maskTouch | K.maskTouching, x: cx, y: cy)
            Thread.sleep(forTimeInterval: Double(max(durationMs, 50)) / Double(steps) / 1000.0)
        }
        Thread.sleep(forTimeInterval: 0.05)
        guard dispatchDigitizer(mask: K.maskRange | K.maskTouch, x: endX, y: endY) else { return false }
        return true
    }
}

// MARK: - 全屏截图（v2.9.182：不再使用 ReplayKit）
// 实证：iOS 16.3 侧载环境 RPScreenRecorder 系统级崩溃（CFRetain SIGTRAP，
// 崩溃栈 sig_1789582255 / sig_1789588011：ReplayKit frame3 CFRetain+0，信号级无法 try-catch）。
// 方案：1) 优先 ControlAgent 注入截图（目标 App 内截自己窗口，零权限零崩溃）
//       2) 兜底截 TrollAgent 自身窗口（AI 召唤时可见聊天界面）
//       3) 均不可用 → 明确返回降级提示，绝不调用 RPScreenRecorder。

final class ScreenCapture {
    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow }
    }

    /// 截当前屏幕（安全版，无 ReplayKit）。
    static func take(completion: @escaping (Bool, String) -> Void) {
        // 1) 优先：ControlAgent 注入截图（目标 App 在线时走 localhost:4789 /screenshot）
        let controlResult = ControlAgentTools.shared.screenshot()
        if controlResult["screenshot"] as? Bool == true, let path = controlResult["path"] as? String {
            DispatchQueue.main.async { completion(true, path) }
            return
        }
        // 2) 兜底：截 TrollAgent 自身窗口（drawViewHierarchy，零权限）
        if let window = keyWindow() {
            let format = UIGraphicsImageRendererFormat()
            format.scale = UIScreen.main.scale
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
            let img = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let dir = Workspace.root.appendingPathComponent("control_shots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("shot_\(Int(Date().timeIntervalSince1970)).png")
            if let data = img.pngData(), (try? data.write(to: url)) != nil {
                DispatchQueue.main.async { completion(true, url.path) }
                return
            }
        }
        // 3) 明确降级（不再触发 ReplayKit 系统崩溃）
        DispatchQueue.main.async {
            completion(false, "此设备录屏不可用：iOS 16.3 侧载环境 ReplayKit 系统级崩溃（已实证 CFRetain SIGTRAP，无法捕获）。请：1. 注入目标 App 并重启后，用 control.screenshot 截屏；2. 或直接用 ui_tree / ui.tap 读取与操作界面。")
        }
    }
}

final class ProgressNotifier {
    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

// MARK: - MCP 工具：ui.* 控制任意 App

final class UITapTool: MCPTool {
    let definition = ToolDefinition(name: "ui.tap",
        summary: "Tap at screen coordinates. Use for: fallback when ControlAgent is NOT injected. Don't use for: normal taps (use control.tap which is more precise). Example: user says '点屏幕中间那个按钮' → tap at coordinates.",
        parameters: ["x": "X coordinate (points)", "y": "Y coordinate (points)", "reason": "Why tap here (optional)"], verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw MCPError.invalidParams("x, y required（浮点 points）")
        }
        let reason = params["reason"] as? String ?? ""
        ControlSession.shared.addThink(reason)
        ControlSession.shared.addAction("ui.tap(\(Int(x)), \(Int(y)))")
        MacroRecorder.shared.capture(tool: "ui.tap", params: ["x": x, "y": y, "reason": reason])
        let ok = HIDTouchInjector.shared.tap(x: Float(x), y: Float(y))
        guard ok else {
            ControlSession.shared.addResult("❌ ui.tap 失败")
            throw MCPError.failed("HID 触摸注入失败：请确认 App 已用 TrollStore 安装并带 com.apple.private.hid.client.event-dispatch 权限（当前 App 已声明）")
        }
        ControlSession.shared.addResult("✅ 已点击 (\(Int(x)), \(Int(y)))")
        return ["message": "已点击 (\(Int(x)), \(Int(y)))", "x": Int(x), "y": Int(y)]
    }
}

final class UISwipeTool: MCPTool {
    let definition = ToolDefinition(name: "ui.swipe",
        summary: "Swipe on the screen. Use for: fallback when ControlAgent is NOT injected. Don't use for: normal swipes (use control.swipe which is more precise). Example: user says '向上滑一下' → swipe up.",
        parameters: ["x1": "Start X coordinate", "y1": "Start Y coordinate", "x2": "End X coordinate", "y2": "End Y coordinate", "duration_ms": "Swipe duration (default: 300ms)", "reason": "Why swipe (optional)"], verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x1 = params["x1"] as? Double, let y1 = params["y1"] as? Double,
              let x2 = params["x2"] as? Double, let y2 = params["y2"] as? Double else {
            throw MCPError.invalidParams("x1,y1,x2,y2 required")
        }
        let dur = params["duration_ms"] as? Int ?? 300
        let reason = params["reason"] as? String ?? ""
        ControlSession.shared.addThink(reason)
        ControlSession.shared.addAction("ui.swipe (\(Int(x1)),\(Int(y1)))→(\(Int(x2)),\(Int(y2))) \(dur)ms")
        MacroRecorder.shared.capture(tool: "ui.swipe", params: ["x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration_ms": dur, "reason": reason])
        let ok = HIDTouchInjector.shared.swipe(x1: Float(x1), y1: Float(y1), x2: Float(x2), y2: Float(y2), durationMs: dur)
        guard ok else {
            ControlSession.shared.addResult("❌ ui.swipe 失败")
            throw MCPError.failed("HID 滑动注入失败：权限或 IOKit 符号不可用")
        }
        ControlSession.shared.addResult("✅ 已滑动")
        return ["message": "已滑动", "from": [x1, y1], "to": [x2, y2]]
    }
}

final class UILongPressTool: MCPTool {
    let definition = ToolDefinition(name: "ui.long_press",
        summary: "Long press on screen coordinates. Use for: fallback when ControlAgent is NOT injected. Don't use for: normal long presses (use control.tap with long duration). Example: user says '长按这个图标' → long press.",
        parameters: ["x": "X coordinate", "y": "Y coordinate", "duration_ms": "Press duration (default: 800ms)", "reason": "Why (optional)"], verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw MCPError.invalidParams("x, y required")
        }
        let dur = params["duration_ms"] as? Int ?? 800
        let reason = params["reason"] as? String ?? ""
        ControlSession.shared.addThink(reason)
        ControlSession.shared.addAction("ui.long_press(\(Int(x)), \(Int(y))) \(dur)ms")
        MacroRecorder.shared.capture(tool: "ui.long_press", params: ["x": x, "y": y, "duration_ms": dur, "reason": reason])
        let ok = HIDTouchInjector.shared.longPress(x: Float(x), y: Float(y), durationMs: dur)
        guard ok else {
            ControlSession.shared.addResult("❌ ui.long_press 失败")
            throw MCPError.failed("HID 长按注入失败")
        }
        ControlSession.shared.addResult("✅ 已长按")
        return ["message": "已长按 (\(Int(x)), \(Int(y))) \(dur)ms"]
    }
}

final class UIClipboardTool: MCPTool {
    let definition = ToolDefinition(name: "ui.clipboard",
        summary: "Copy text to system clipboard. Use for: paste text into apps (long-press + Paste). Don't use for: read clipboard (use clipboard.read), type text directly (use control.type). Example: user says '复制这段文字到输入框' → write to clipboard.",
        parameters: ["text": "Text to copy", "reason": "Why (optional)"], verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else { throw MCPError.invalidParams("text required") }
        let reason = params["reason"] as? String ?? ""
        ControlSession.shared.addThink(reason)
        ControlSession.shared.addAction("ui.clipboard: \(text.count) 字符")
        MacroRecorder.shared.capture(tool: "ui.clipboard", params: ["text": text, "reason": reason])
        UIThreadBridge.paste(text)
        ControlSession.shared.addResult("✅ 已写入剪贴板，下一步长按输入框+点粘贴")
        return ["message": "已写入剪贴板 \(text.count) 字符，请用 ui.long_press 长按输入框后点击「粘贴」", "copied": text.count]
    }
}

final class UIScreenshotTool: MCPTool {
    let definition = ToolDefinition(name: "ui.screenshot",
        summary: "Take a screenshot of current screen. Use for: fallback when ControlAgent is NOT injected. Don't use for: normal screenshots (use control.screenshot which is more reliable). Example: user says '截个屏看看' → take screenshot.",
        parameters: ["reason": "Why screenshot (optional)"], verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let reason = params["reason"] as? String ?? ""
        ControlSession.shared.addThink(reason.isEmpty ? "截屏验证当前界面" : reason)
        ControlSession.shared.addAction("ui.screenshot")
        var out: [String: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        ScreenCapture.take { ok, detail in
            out["ok"] = ok
            out["detail"] = detail
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        guard out["ok"] as? Bool == true, let path = out["detail"] as? String else {
            ControlSession.shared.addResult("❌ 截图失败")
            throw MCPError.failed(out["detail"] as? String ?? "截图超时")
        }
        ControlSession.shared.lastScreenshotPath = path
        ControlSession.shared.addResult("📸 截图已保存")
        return ["message": "截图已保存: \(path)", "path": path]
    }
}

// MARK: - 进度横幅（执行中节点汇报）

final class ProgressNotifyTool: MCPTool {
    let definition = ToolDefinition(name: "progress.notify",
        summary: "Show a system notification banner. Use for: report progress during long automation tasks. Don't use for: send message (use send_message), take screenshot (use ui.screenshot). Example: user says '自动化的时候通知我进度' → notify.",
        parameters: ["title": "Notification title", "body": "Notification content"], verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String, !title.isEmpty else {
            throw MCPError.invalidParams("title required")
        }
        let body = params["body"] as? String ?? ""
        ProgressNotifier.notify(title: title, body: body)
        ControlSession.shared.addResult("🔔 \(title) \(body)")
        return ["message": "已发送进度通知", "title": title, "body": body]
    }
}

// MARK: - 控制会话（计划→执行→报告）

final class ControlBeginTool: MCPTool {
    let definition = ToolDefinition(name: "control.begin",
        summary: "Start an AI app-control session. Use for: begin a multi-step automation task, show progress UI. Don't use for: single tap/swipe (use control.tap/swipe directly). Example: user says '帮我在美团上点个外卖' → start control session.",
        parameters: ["target": "Target app name", "bundle_id": "Target bundle ID (optional)", "plan": "List of planned steps"],
        verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let target = params["target"] as? String, !target.isEmpty else {
            throw MCPError.invalidParams("target required")
        }
        let plan = params["plan"] as? [String] ?? ["开始执行"]
        let bundleId = params["bundle_id"] as? String ?? ""
        ControlSession.shared.begin(target: target, bundleId: bundleId, plan: plan)
        return ["message": "控制会话已开始：\(target)，共 \(plan.count) 步。用户正在控制中心查看进度。",
                "steps": plan.enumerated().map { ["index": $0.offset, "title": $0.element] }]
    }
}

final class ControlUpdateTool: MCPTool {
    let definition = ToolDefinition(name: "control.update",
        summary: "Update progress of a control session. Use for: during automation, report each step's status to user. Don't use for: start control session (use control.begin), end session (use control.end). Example: user says '自动化执行到第3步了，更新一下进度' → update status.",
        parameters: ["step": "Step number (0-based)", "status": "pending/running/done/failed", "detail": "Details (optional)", "reason": "Why (optional)"],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let idx = params["step"] as? Int else { throw MCPError.invalidParams("step required") }
        let reason = params["reason"] as? String ?? ""
        ControlSession.shared.addThink(reason)
        let raw = params["status"] as? String ?? "done"
        let st: ControlStep.StepStatus
        switch raw {
        case "running": st = .running
        case "failed": st = .failed
        case "pending": st = .pending
        default: st = .done
        }
        let detail = params["detail"] as? String ?? ""
        ControlSession.shared.updateStep(index: idx, status: st, detail: detail)
        return ["message": "步骤\(idx + 1) 已更新为 \(raw)", "step": idx, "status": raw]
    }
}

final class ControlFinishTool: MCPTool {
    let definition = ToolDefinition(name: "control.finish",
        summary: "End a control session. Use for: finish automation task, report final result to user. Don't use for: start session (use control.begin), update progress (use control.update). Example: user says '自动化完成了，结束会话' → finish control session.",
        parameters: ["result": "Final result summary"],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let result = params["result"] as? String ?? "完成"
        ControlSession.shared.finish(result: result)
        return ["message": "控制会话已结束", "result": result]
    }
}
