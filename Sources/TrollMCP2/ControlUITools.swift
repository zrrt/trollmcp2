import Foundation
import UIKit
import UserNotifications
import CoreMedia
import ReplayKit

// MARK: - v2.9.139 HID 触摸注入（TrollStore 无沙箱 + com.apple.private.hid.client.event-dispatch）
// 原理：IOHIDEventSystemClient 创建 digitizer 触摸事件并分发到系统，
// 可对任意前台 App（美团/微信等）合成点击/滑动/长按——AI 控制任意 App UI 的关键能力。
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

// MARK: - 全屏截图（ReplayKit：AI 控制目标 App 时验证现场证据）
// 需用户首次授权「录屏」；授权后可在任何前台 App 下截全屏。

final class ScreenCapture {
    static func take(completion: @escaping (Bool, String) -> Void) {
        guard RPScreenRecorder.shared().isAvailable else {
            completion(false, "RPScreenRecorder 不可用")
            return
        }
        RPScreenRecorder.shared().takeScreenshot { sampleBuffer, error in
            if let err = error {
                completion(false, "截图失败: \(err.localizedDescription)（需在系统设置允许 TrollAgent 录屏）")
                return
            }
            guard let buf = sampleBuffer else {
                completion(false, "截图返回空")
                return
            }
            guard let pixel = CMSampleBufferGetImageBuffer(buf) else {
                completion(false, "截图转码失败")
                return
            }
            let ci = CIImage(cvPixelBuffer: pixel)
            let ctx = CIContext()
            guard let cg = ctx.createCGImage(ci, from: ci.extent) else {
                completion(false, "CGImage 生成失败")
                return
            }
            let img = UIImage(cgImage: cg)
            let dir = Workspace.root.appendingPathComponent("control_shots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("shot_\(Int(Date().timeIntervalSince1970)).png")
            guard let data = img.pngData() else {
                completion(false, "PNG 编码失败")
                return
            }
            do {
                try data.write(to: url)
                completion(true, url.path)
            } catch {
                completion(false, "保存失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 节点横幅（执行中进度汇报：本地通知立即弹出，任何 App 界面顶部可见）

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
        summary: "在屏幕指定坐标点击（AI 控制任意前台 App：美团/微信等）。坐标用 points（iPhone 全屏约 390x844 逻辑点），原点左上角。",
        parameters: ["x": "横坐标 points", "y": "纵坐标 points"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw MCPError.invalidParams("x, y required（浮点 points）")
        }
        ControlSession.shared.addLog("ui.tap(\(Int(x)), \(Int(y)))")
        let ok = HIDTouchInjector.shared.tap(x: Float(x), y: Float(y))
        guard ok else {
            throw MCPError.failed("HID 触摸注入失败：请确认 App 已用 TrollStore 安装并带 com.apple.private.hid.client.event-dispatch 权限（当前 App 已声明）")
        }
        ControlSession.shared.addLog("  ✅ 已点击 (\(Int(x)), \(Int(y)))")
        return ["message": "已点击 (\(Int(x)), \(Int(y)))", "x": Int(x), "y": Int(y)]
    }
}

final class UISwipeTool: MCPTool {
    let definition = ToolDefinition(name: "ui.swipe",
        summary: "在屏幕滑动（从 A 到 B），用于翻页/滚动/返回手势。",
        parameters: ["x1": "起点横坐标", "y1": "起点纵坐标", "x2": "终点横坐标", "y2": "终点纵坐标", "duration_ms": "时长毫秒（默认 300）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x1 = params["x1"] as? Double, let y1 = params["y1"] as? Double,
              let x2 = params["x2"] as? Double, let y2 = params["y2"] as? Double else {
            throw MCPError.invalidParams("x1,y1,x2,y2 required")
        }
        let dur = params["duration_ms"] as? Int ?? 300
        ControlSession.shared.addLog("ui.swipe (\(Int(x1)),\(Int(y1)))→(\(Int(x2)),\(Int(y2))) \(dur)ms")
        let ok = HIDTouchInjector.shared.swipe(x1: Float(x1), y1: Float(y1), x2: Float(x2), y2: Float(y2), durationMs: dur)
        guard ok else {
            throw MCPError.failed("HID 滑动注入失败：权限或 IOKit 符号不可用")
        }
        ControlSession.shared.addLog("  ✅ 已滑动")
        return ["message": "已滑动", "from": [x1, y1], "to": [x2, y2]]
    }
}

final class UILongPressTool: MCPTool {
    let definition = ToolDefinition(name: "ui.long_press",
        summary: "长按屏幕坐标（弹出菜单/选择文本/粘贴菜单用）。",
        parameters: ["x": "横坐标", "y": "纵坐标", "duration_ms": "长按时长毫秒（默认 800）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw MCPError.invalidParams("x, y required")
        }
        let dur = params["duration_ms"] as? Int ?? 800
        ControlSession.shared.addLog("ui.long_press(\(Int(x)), \(Int(y))) \(dur)ms")
        let ok = HIDTouchInjector.shared.longPress(x: Float(x), y: Float(y), durationMs: dur)
        guard ok else {
            throw MCPError.failed("HID 长按注入失败")
        }
        ControlSession.shared.addLog("  ✅ 已长按")
        return ["message": "已长按 (\(Int(x)), \(Int(y))) \(dur)ms"]
    }
}

final class UIClipboardTool: MCPTool {
    let definition = ToolDefinition(name: "ui.clipboard",
        summary: "把文本写入系统剪贴板（配合 ui.long_press 长按输入框 + 点「粘贴」实现跨 App 文本输入；iOS 无直接注入文本的公开 API）。",
        parameters: ["text": "要写入剪贴板的文本"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else { throw MCPError.invalidParams("text required") }
        UIPasteboard.general.string = text
        ControlSession.shared.addLog("ui.clipboard: 已写入 \(text.count) 字符")
        return ["message": "已写入剪贴板 \(text.count) 字符，请用 ui.long_press 长按输入框后点击「粘贴」", "copied": text.count]
    }
}

final class UIScreenshotTool: MCPTool {
    let definition = ToolDefinition(name: "ui.screenshot",
        summary: "截取当前屏幕（任意前台 App，ReplayKit）。返回图片路径供验证；首次使用需系统授权录屏。",
        parameters: [:])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        var out: [String: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        ScreenCapture.take { ok, detail in
            out["ok"] = ok
            out["detail"] = detail
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        guard out["ok"] as? Bool == true, let path = out["detail"] as? String else {
            throw MCPError.failed(out["detail"] as? String ?? "截图超时")
        }
        ControlSession.shared.lastScreenshotPath = path
        ControlSession.shared.addLog("ui.screenshot → \(path)")
        return ["message": "截图已保存: \(path)（可用 fs.read 或让用户查看）", "path": path]
    }
}

// MARK: - 进度横幅（执行中节点汇报）

final class ProgressNotifyTool: MCPTool {
    let definition = ToolDefinition(name: "progress.notify",
        summary: "AI 控制 App 执行中，向用户弹系统通知横幅（任何界面顶部可见）汇报节点进度。",
        parameters: ["title": "标题（如 ✅ 已选择店铺）", "body": "正文（如 汉堡王·第2家店）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String, !title.isEmpty else {
            throw MCPError.invalidParams("title required")
        }
        let body = params["body"] as? String ?? ""
        ProgressNotifier.notify(title: title, body: body)
        ControlSession.shared.addLog("progress.notify: \(title) \(body)")
        return ["message": "已发送进度通知", "title": title, "body": body]
    }
}

// MARK: - 控制会话（计划→执行→报告）

final class ControlBeginTool: MCPTool {
    let definition = ToolDefinition(name: "control.begin",
        summary: "开始一次「AI 控制任意 App」会话：登记目标 App 与执行计划（AI 每步完成后用 control.update 汇报，UI 实时展示；目标 App 需先用启动工具唤醒到前台）。",
        parameters: ["target": "目标 App 名称（如 美团）", "bundle_id": "目标 Bundle ID（可选）", "plan": "计划步骤数组（字符串列表）"])
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
        summary: "更新控制会话某一步的状态（running/done/failed）+ 详情，UI 实时刷新。",
        parameters: ["step": "步骤序号（从 0 开始）", "status": "pending/running/done/failed", "detail": "详情（可选）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let idx = params["step"] as? Int else { throw MCPError.invalidParams("step required") }
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
        summary: "结束控制会话，登记最终结果（UI 展示完整报告）。",
        parameters: ["result": "结果总结（做了什么/卡在哪/下一步）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let result = params["result"] as? String ?? "完成"
        ControlSession.shared.finish(result: result)
        return ["message": "控制会话已结束", "result": result]
    }
}
