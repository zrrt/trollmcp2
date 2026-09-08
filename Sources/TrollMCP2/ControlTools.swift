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
        request.httpMethod = method
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

    func inject(bundleId: String) -> [String: Any] {
        // 找到内置的 ControlAgent.dylib
        let dylibPath = Bundle.main.path(forResource: "ControlAgent", ofType: "dylib", inDirectory: "tweaks")
        guard dylibPath != nil else {
            // 尝试工作区路径
            let workspacePath = "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)/Workspace/tweaks/ControlAgent.dylib"
            guard FileManager.default.fileExists(atPath: workspacePath) else {
                return ["error": "ControlAgent.dylib 未内置，请先编译并放入 Resources/tweaks/", "hint": "线上编译 build-tweak workflow"]
            }
            return doInject(bundleId: bundleId, dylibPath: workspacePath)
        }
        return doInject(bundleId: bundleId, dylibPath: dylibPath!)
    }

    private func doInject(bundleId: String, dylibPath: String) -> [String: Any] {
        do {
            let result = try InjectionManager.shared.enable(
                bundleId: bundleId,
                dylibName: "@executable_path/ControlAgent.dylib",
                dylibSourcePath: dylibPath
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
            return ["error": "注入失败: \(error.localizedDescription)", "bundle_id": bundleId]
        }
    }

    // MARK: - 状态检查

    func status() -> [String: Any] {
        let (code, data, error) = request(path: "/status")
        if code == 200 {
            var result = parseJSON(data)
            result["connected"] = true
            return result
        }
        return [
            "connected": false,
            "error": error ?? "HTTP \(code)",
            "hint": "请确认：1. ControlAgent.dylib 已注入 2. 目标 App 正在运行 3. 注入后已重启目标 App"
        ]
    }

    // MARK: - UI 树

    func uiTree() -> [String: Any] {
        let (code, data, error) = request(path: "/ui_tree")
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
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
            return [
                "screenshot": true,
                "path": path.path,
                "size": data.count,
                "hint": "用 artifact.read_text 或 artifact.find 查看截图"
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
            "bundle_id": "目标 App 的 Bundle ID，用 injection.list 搜索获取（必填）"
        ]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        AuditLog.shared.log("control.inject", detail: bundleId)
        return ControlAgentTools.shared.inject(bundleId: bundleId)
    }
}

final class ControlStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.status",
        summary: "检查目标 App 的 ControlAgent 是否在线（localhost:4789 是否可连接）。返回 App 信息、PID、可用 API 列表。",
        parameters: [:]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return ControlAgentTools.shared.status()
    }
}

final class ControlUITreeTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.ui_tree",
        summary: "获取目标 App 当前的完整 UI 树（所有窗口、视图、frame、text、可访问性信息）。AI 根据 UI 树决定点击哪个元素。限制 500 节点。",
        parameters: [:]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        AuditLog.shared.log("control.ui_tree", detail: "dump")
        return ControlAgentTools.shared.uiTree()
    }
}

final class ControlScreenshotTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.screenshot",
        summary: "截取目标 App 当前屏幕，保存为 PNG 到工作区 screenshots/ 目录。返回文件路径，用 artifact.find 定位。",
        parameters: [:]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        AuditLog.shared.log("control.screenshot", detail: "capture")
        return ControlAgentTools.shared.screenshot()
    }
}

final class ControlTapTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.tap",
        summary: "在目标 App 屏幕上模拟点击。参数 x,y 为屏幕坐标（从 ui_tree 的 frame 获取）。",
        parameters: [
            "x": "点击 X 坐标（必填，数字）",
            "y": "点击 Y 坐标（必填，数字）"
        ]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw MCPError.invalidParams("x and y required (numbers)")
        }
        AuditLog.shared.log("control.tap", detail: "(\(x),\(y))")
        return ControlAgentTools.shared.tap(x: x, y: y)
    }
}

final class ControlSwipeTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.swipe",
        summary: "在目标 App 屏幕上模拟滑动。参数 x1,y1 起点，x2,y2 终点，duration 滑动时长（秒，默认0.3）。",
        parameters: [
            "x1": "起点 X（必填）", "y1": "起点 Y（必填）",
            "x2": "终点 X（必填）", "y2": "终点 Y（必填）",
            "duration": "滑动时长秒，默认0.3"
        ]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let x1 = params["x1"] as? Double, let y1 = params["y1"] as? Double,
              let x2 = params["x2"] as? Double, let y2 = params["y2"] as? Double else {
            throw MCPError.invalidParams("x1,y1,x2,y2 required")
        }
        let duration = params["duration"] as? Double ?? 0.3
        AuditLog.shared.log("control.swipe", detail: "(\(x1),\(y1))→(\(x2),\(y2))")
        return ControlAgentTools.shared.swipe(x1: x1, y1: y1, x2: x2, y2: y2, duration: duration)
    }
}

final class ControlTypeTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.type",
        summary: "在目标 App 当前输入框（第一响应者）输入文字。如果没有输入框被选中，文字会复制到剪贴板。",
        parameters: ["text": "要输入的文字（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else {
            throw MCPError.invalidParams("text required")
        }
        AuditLog.shared.log("control.type", detail: text)
        return ControlAgentTools.shared.type(text: text)
    }
}

final class ControlKeyTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.key",
        summary: "模拟按键。支持 home（返回桌面）、back（返回）、enter（回车）。",
        parameters: ["key": "home/back/enter（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let key = params["key"] as? String else {
            throw MCPError.invalidParams("key required")
        }
        AuditLog.shared.log("control.key", detail: key)
        return ControlAgentTools.shared.key(key)
    }
}
