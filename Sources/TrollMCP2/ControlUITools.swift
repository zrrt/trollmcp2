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

// MARK: - 全屏截图（ReplayKit：AI 控制目标 App 时验证现场证据）
// 需用户首次授权「录屏」；授权后可在任何前台 App 下截全屏。

final class ScreenCapture {
    /// 截当前屏幕（含任意前台 App）：ReplayKit startCapture 取首帧视频后立即停止。
    /// 需首次录屏授权；授权后可截任意前台 App（AI 控制目标 App 时的现场证据）。
    /// v2.9.174：防秒崩重写——
    ///  1) done 竞态用 NSLock 保护（原布尔在 handler 线程与 8s 兜底线程无锁竞争）
    ///  2) CIContext 用软件渲染（避免后台线程无 GPU/Metal 上下文时崩溃）
    ///  3) 图像转换包 autoreleasepool（ReplayKit buffer 生命周期：stopCapture 后 buffer 可能被系统回收）
    ///  4) completion 统一回主线程（防调用方在主线程做 UI 时崩）
    ///  5) startCapture 前若残留录制状态先 stop（764369 官方建议）
    static func take(completion: @escaping (Bool, String) -> Void) {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            DispatchQueue.main.async { completion(false, "RPScreenRecorder 不可用") }
            return
        }
        // 残留录制状态清理（上次异常退出可能没 stop 干净）
        if recorder.isRecording {
            recorder.stopCapture { _ in }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // v2.9.178：不再"首帧立即停"——RPScreenRecorder 不是为录一帧就停设计，
        // 秒开秒停在 stopCapture 内部 CFRetain 断言（SIGTRAP，用户复现日志 sig_1789582255：
        // ReplayKit frame3 CFRetain+0）。改为：持续缓存最新帧 → 收帧后延迟 0.6s
        // 再 stop → stop 完成后统一落盘（不碰活 buffer）。
        let lock = NSLock()
        var done = false
        var scheduled = false
        var latestImage: UIImage?
        let finish: (Bool, String) -> Void = { ok, msg in
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            lock.unlock()
            DispatchQueue.main.async { completion(ok, msg) }
        }
        let saveLatest: () -> Void = {
            lock.lock()
            let img = latestImage
            lock.unlock()
            guard let img else {
                recorder.stopCapture { _ in }
                finish(false, "未捕获到视频帧")
                return
            }
            let dir = Workspace.root.appendingPathComponent("control_shots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("shot_\(Int(Date().timeIntervalSince1970)).png")
            guard let data = img.pngData() else {
                recorder.stopCapture { _ in }
                finish(false, "PNG 编码失败")
                return
            }
            do {
                try data.write(to: url)
                finish(true, url.path)
            } catch {
                recorder.stopCapture { _ in }
                finish(false, "保存失败: \(error.localizedDescription)")
            }
        }
        recorder.startCapture(handler: { sampleBuffer, bufferType, _ in
            guard bufferType == .video else { return }
            lock.lock()
            if done { lock.unlock(); return }
            lock.unlock()
            autoreleasepool {
                guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let ctx = CIContext(options: [.useSoftwareRenderer: true])
                let ci = CIImage(cvPixelBuffer: pixel)
                guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
                let img = UIImage(cgImage: cg)
                lock.lock()
                latestImage = img
                lock.unlock()
            }
        }) { error in
            if let error {
                recorder.stopCapture { _ in }
                finish(false, "录屏失败: \(error.localizedDescription)")
            }
        }
        // v2.9.179：固定 0.8s 后停（不依赖首帧——旧版等首帧才调度 stop，无帧就永远卡死，
        // 表现为"AI 一直思考"）。无论有没有帧都必停必返回。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            recorder.stopCapture { _ in
                saveLatest()
            }
        }
        // v2.9.179：12s 总超时兜底——startCapture 的 completionHandler 在 TrollStore 环境
        // 可能不被调用（授权弹窗未响应/系统卡住），此时 0.8s stop 也无帧可存，需要强制收尾
        // 返回结果，绝不无限挂起。
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            lock.lock()
            let img = latestImage
            lock.unlock()
            if img == nil {
                recorder.stopCapture { _ in }
                finish(false, "录屏超时：TrollStore 环境 ReplayKit 无响应。请确认授权弹窗已允许；仍不行则改用注入截图。")
            } else {
                saveLatest()
            }
        }
    }}

// MARK: - MCP 工具：ui.* 控制任意 App

final class UITapTool: MCPTool {
    let definition = ToolDefinition(name: "ui.tap",
        summary: "在屏幕指定坐标点击（AI 控制任意前台 App：美团/小红书等）。坐标用 points（iPhone 全屏约 390x844 逻辑点），原点左上角。调用时务必带 reason 说明判断依据（为什么点这里）。",
        parameters: ["x": "横坐标 points", "y": "纵坐标 points", "reason": "判断依据（必填，如：截图显示搜索框在 (100,55)）"])
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
        summary: "在屏幕滑动（从 A 到 B），用于翻页/滚动/返回手势。调用时务必带 reason 说明判断依据。",
        parameters: ["x1": "起点横坐标", "y1": "起点纵坐标", "x2": "终点横坐标", "y2": "终点纵坐标", "duration_ms": "时长毫秒（默认 300）", "reason": "判断依据（必填）"])
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
        summary: "长按屏幕坐标（弹出菜单/选择文本/粘贴菜单用）。调用时务必带 reason。",
        parameters: ["x": "横坐标", "y": "纵坐标", "duration_ms": "长按时长毫秒（默认 800）", "reason": "判断依据（必填）"])
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
        summary: "把文本写入系统剪贴板（配合 ui.long_press 长按输入框 + 点「粘贴」实现跨 App 文本输入；iOS 无直接注入文本的公开 API）。调用时务必带 reason。",
        parameters: ["text": "要写入剪贴板的文本", "reason": "判断依据（必填）"])
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
        summary: "截取当前屏幕（任意前台 App，ReplayKit）。返回图片路径供 AI 验证界面状态；首次使用需系统授权录屏。调用时务必带 reason 说明要验证什么。",
        parameters: ["reason": "验证目的（必填，如：确认搜索框是否弹出）"])
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
        summary: "AI 控制 App 执行中，向用户弹系统通知横幅（任何界面顶部可见）汇报节点进度。",
        parameters: ["title": "标题（如 ✅ 已选择店铺）", "body": "正文（如 汉堡王·第2家店）"])
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
        parameters: ["step": "步骤序号（从 0 开始）", "status": "pending/running/done/failed", "detail": "详情（可选）", "reason": "判断依据（可选）"])
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
        summary: "结束控制会话，登记最终结果（UI 展示完整报告）。",
        parameters: ["result": "结果总结（做了什么/卡在哪/下一步）"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let result = params["result"] as? String ?? "完成"
        ControlSession.shared.finish(result: result)
        return ["message": "控制会话已结束", "result": result]
    }
}
