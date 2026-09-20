import Foundation

// v2.9.75：ControlAgent 通用 UI 控制工具
// 注入 ControlAgent.dylib 到任意 App 后，通过 localhost HTTP 控制目标 App UI
// 端口固定 4789，API: /status /ui_tree /screenshot /tap /swipe /type /key

final class ControlAgentTools {
    static let shared = ControlAgentTools()
    private let port = 4789
    private let timeout: TimeInterval = 5

    // MARK: - 通用 HTTP 请求

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil) -> (Int, Data?, String?) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        setHTTPMethod(method, on: &request)
        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var resultData: Data?
        var resultError: String?
        var statusCode = 0
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                resultError = error.localizedDescription
            } else if let httpResponse = response as? HTTPURLResponse {
                statusCode = httpResponse.statusCode
                resultData = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        return (statusCode, resultData, resultError)
    }

    private func parseJSON(_ data: Data?) -> [String: Any] {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - 注入 ControlAgent.dylib

    func inject(bundleId: String, target: String? = nil, skipProbe: Bool = false) -> [String: Any] {
        // 找到内置的 ControlAgent.dylib
        let dylibPath = Bundle.main.path(forResource: "ControlAgent", ofType: "dylib", inDirectory: "tweaks")
        guard dylibPath != nil else {
            // 尝试工作区路径
            let workspacePath = "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)/Workspace/tweaks/ControlAgent.dylib"
            guard FileManager.default.fileExists(atPath: workspacePath) else {
                return ["error": "ControlAgent.dylib 未内置，请先编译并放入 Resources/tweaks/", "hint": "线上编译 build-tweak workflow"]
            }
            return doInject(bundleId: bundleId, dylibPath: workspacePath, target: target, skipProbe: skipProbe)
        }
        return doInject(bundleId: bundleId, dylibPath: dylibPath!, target: target, skipProbe: skipProbe)
    }

    private func doInject(bundleId: String, dylibPath: String, target: String? = nil, skipProbe: Bool = false) -> [String: Any] {
        do {
            // v2.9.260：控制代理必须注入主二进制（启动必加载）——懒加载 framework 实测
            // ControlAgent constructor 不执行、4789 不监听（小红书 AppsFlyerLib 实锤）。
            // 主二进制加密的 load commands 不加密，insert_dylib+伪签+ct_bypass 可改。
            let result = try InjectionManager.shared.enable(
                bundleId: bundleId,
                dylibName: "@executable_path/ControlAgent.dylib",
                dylibSourcePath: dylibPath,
                preferredTarget: target,
                skipProbe: skipProbe,
                allowMain: true
            )
            // v2.9.109：注入成功自动开启真后台保活（目标 App + TrollAgent 自身），
            // 防止目标 App 切后台被系统挂起导致 4789 断连
            postKeepAliveNotification(true)
            BackgroundKeepAlive.shared.start()
            return [
                "injected": true,
                "bundle_id": bundleId,
                "dylib": dylibPath,
                "detail": result,
                "keepalive": true,
                "next_step": "启动目标 App 后调用 control.status 确认连接，然后用 control.ui_tree / control.tap 等控制；真后台保活已开启，目标 App 切后台不挂起"
            ]
        } catch {
            // v2.9.189：用 \(error) 而非 localizedDescription——纯 Swift Error 的
            // localizedDescription 会被 NSError bridge 抹成"未能完成操作。"，真实原因丢失
            return ["error": "注入失败: \(error)", "bundle_id": bundleId]
        }
    }

    // MARK: - 状态检查
    // v2.9.128：自动重试（ControlAgent 服务器在 App 启动后 ~1.5s 才监听 4789，
    // 刚注入/刚启动立刻查会连接拒绝）——status 最多试 4 次，间隔 0.6s

    func status(retries: Int = 4) -> [String: Any] {
        var lastErr: String? = nil
        var lastCode = 0
        for attempt in 0..<max(1, retries) {
            let (code, data, error) = request(path: "/status")
            if code == 200 {
                var result = parseJSON(data)
                result["connected"] = true
                if attempt > 0 { result["retries"] = attempt }
                return result
            }
            lastErr = error
            lastCode = code
            Thread.sleep(forTimeInterval: 0.6)
        }
        return [
            "connected": false,
            "error": lastErr ?? "HTTP \(lastCode)",
            "hint": "确认：1. ControlAgent.dylib 已注入 2. 目标 App 正在运行 3. 注入后已重启目标 App（服务器在启动后约 1.5s 就绪）"
        ]
    }

    // MARK: - v2.9.186 进程内砸壳
    // 调 ControlAgent /decrypt：目标进程内遍历 dyld 镜像，从内存读已解密段写副本
    // 绕开 TrollStore 无 task_for_pid 的限制。返回各镜像解密结果（output 为容器内副本路径）。

    func decrypt() -> [String: Any] {
        var lastErr: String? = nil
        for attempt in 0..<4 {
            let (code, data, error) = request(path: "/decrypt")
            if code == 200 {
                var json = parseJSON(data)
                json["connected"] = true
                if attempt > 0 { json["retries"] = attempt }
                return json
            }
            lastErr = error
            Thread.sleep(forTimeInterval: 0.8)
        }
        return [
            "connected": false,
            "error": lastErr ?? "decrypt endpoint unreachable",
            "hint": "确认 ControlAgent 已注入且目标 App 正在运行（服务器启动后约 1.5s 就绪）"
        ]
    }

    // MARK: - UI 树
    // v2.9.128：服务器刚就绪时首帧可能超时，轻量重试 2 次

    func uiTree() -> [String: Any] {
        var lastErr: String? = nil
        var lastCode = 0
        for attempt in 0..<3 {
            let (code, data, error) = request(path: "/ui_tree")
            if code == 200 {
                var result = parseJSON(data)
                if attempt > 0 { result["retries"] = attempt }
                return result
            }
            lastErr = error; lastCode = code
            Thread.sleep(forTimeInterval: 0.5)
        }
        return ["error": lastErr ?? "HTTP \(lastCode)", "hint": "确认目标 App 正在运行且 ControlAgent 已注入并重启"]
    }

    // MARK: - 截图

    func screenshot() -> [String: Any] {
        let (code, data, error) = request(path: "/screenshot")
        if code == 200, let data = data {
            // 保存到工作区
            let workspace = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = workspace.appendingPathComponent("Workspace/screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let filename = "control_\(Int(Date().timeIntervalSince1970)).png"
            let path = dir.appendingPathComponent(filename)
            try? data.write(to: path)
            // v3.0.22：自动清理旧截图，只保留最近 10 张
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) {
                let sorted = files.filter { $0.pathExtension == "png" }.sorted {
                    let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return d1 > d2
                }
                if sorted.count > 10 {
                    for old in sorted[10...] {
                        try? fm.removeItem(at: old)
                    }
                }
            }
            // v3.0.65：同时返回 base64（AI 直接看图，不用读文件）
            let base64 = data.base64EncodedString()
            return [
                "screenshot": true,
                "path": path.path,
                "size": data.count,
                "base64": base64,
                "hint": "base64 字段直接看图；path 是文件路径备用"
            ]
        }
        return ["error": error ?? "HTTP \(code)"]
    }

    // MARK: - 点击

    func tap(x: Double, y: Double) -> [String: Any] {
        let (code, data, error) = request(path: "/tap", method: "POST", body: ["x": x, "y": y])
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
    }

    // MARK: - 滑动

    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double = 0.3) -> [String: Any] {
        let (code, data, error) = request(path: "/swipe", method: "POST", body: [
            "x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration": duration
        ])
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
    }

    // MARK: - 输入文字

    func type(text: String) -> [String: Any] {
        let (code, data, error) = request(path: "/type", method: "POST", body: ["text": text])
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
    }

    // MARK: - 按键

    func key(_ key: String) -> [String: Any] {
        let (code, data, error) = request(path: "/key", method: "POST", body: ["key": key])
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
    }
}

// MARK: - MCP 工具注册

final class ControlInjectTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.inject",
        summary: "注入 ControlAgent.dylib 到目标 App，注入后 AI 可通过 localhost HTTP 控制目标 App 的 UI（点击/滑动/输入/截图/读取UI树）。参数 bundle_id 为目标 App 的 Bundle ID。注入后需重启目标 App。",
        parameters: [
            "bundle_id": "Target App bundle_id (required, search via injection.list)",
            "target": "Optional: specific Mach-O to inject (framework name substring, e.g. BiliCr). Default auto-select main binary's mandatory framework",
            "skip_probe": "Optional: skip startup selfcheck after injection (no probe/rollback, preserve for manual verification). Default false"
        ],
        verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        AuditLog.shared.log("control.inject", detail: bundleId)
        return ControlAgentTools.shared.inject(bundleId: bundleId,
                                               target: params["target"] as? String,
                                               skipProbe: params["skip_probe"] as? Bool ?? false)
    }
}

final class ControlStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.status",
        summary: "检查目标 App 的 ControlAgent 是否在线（localhost:4789 是否可连接）。返回 App 信息、PID、可用 API 列表。",
        parameters: [:],
        verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return ControlAgentTools.shared.status()
    }
}

final class ControlUITreeTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.ui_tree",
        summary: "获取目标 App 当前的完整 UI 树（所有窗口、视图、frame、text、可访问性信息）。AI 根据 UI 树决定点击哪个元素。限制 500 节点。",
        parameters: [:],
        verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        AuditLog.shared.log("control.ui_tree", detail: "dump")
        return ControlAgentTools.shared.uiTree()
    }
}

final class ControlScreenshotTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.screenshot",
        summary: "截取目标 App 当前屏幕，保存为 PNG 到工作区 screenshots/ 目录。返回文件路径，用 artifact.find 定位。",
        parameters: [:],
        verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        AuditLog.shared.log("control.screenshot", detail: "capture")
        return ControlAgentTools.shared.screenshot(, category: "ui_control")
    }
}

final class ControlTapTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.tap",
        summary: "在目标 App 屏幕上模拟点击。参数 x,y 为屏幕坐标（从 ui_tree 的 frame 获取）。",
        parameters: [
            "x": "Tap X coordinate (required, number)",
            "y": "Tap Y coordinate (required, number)"
        ],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw MCPError.invalidParams("x and y required (numbers)")
        }
        AuditLog.shared.log("control.tap", detail: "(\(x),\(y))")
        return ControlAgentTools.shared.tap(x: x, y: y, category: "ui_control")
    }
}

final class ControlSwipeTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.swipe",
        summary: "在目标 App 屏幕上模拟滑动。参数 x1,y1 起点，x2,y2 终点，duration 滑动时长（秒，默认0.3）。",
        parameters: [
            "x1": "Start X (required)", "y1": "Start Y (required)",
            "x2": "End X (required)", "y2": "End Y (required)",
            "duration": "Swipe duration seconds (default 0.3)"
        ],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x1 = params["x1"] as? Double, let y1 = params["y1"] as? Double,
              let x2 = params["x2"] as? Double, let y2 = params["y2"] as? Double else {
            throw MCPError.invalidParams("x1,y1,x2,y2 required")
        }
        let duration = params["duration"] as? Double ?? 0.3
        AuditLog.shared.log("control.swipe", detail: "(\(x1),\(y1))→(\(x2),\(y2))")
        return ControlAgentTools.shared.swipe(x1: x1, y1: y1, x2: x2, y2: y2, duration: duration, category: "ui_control")
    }
}

final class ControlTypeTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.type",
        summary: "在目标 App 当前输入框（第一响应者）输入文字。如果没有输入框被选中，文字会复制到剪贴板。",
        parameters: ["text": "Text to input (required)"],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else {
            throw MCPError.invalidParams("text required")
        }
        AuditLog.shared.log("control.type", detail: text, category: "ui_control")
        return ControlAgentTools.shared.type(text: text)
    }
}

final class ControlKeyTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.key",
        summary: "模拟按键。支持 home（返回桌面）、back（返回）、enter（回车）。",
        parameters: ["key": "home/back/enter (required)"],
        verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let key = params["key"] as? String else {
            throw MCPError.invalidParams("key required")
        }
        AuditLog.shared.log("control.key", detail: key)
        return ControlAgentTools.shared.key(key)
    }
}
