import Foundation
import UIKit

// MARK: - 文件桥（对齐原版 artifact.* 工具）

final class ArtifactReadTextTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.read_text",
        summary: "读取工作区内文件的文本内容",
        parameters: ["path": "工作区内相对路径"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        let url = try Workspace.resolve(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        return ["content": text]
    }
}

final class ArtifactWriteTextTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.write_text",
        summary: "向工作区写入文本文件（覆盖）",
        parameters: ["path": "工作区内相对路径", "content": "文本内容"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String,
              let content = params["content"] as? String else {
            throw MCPError.invalidParams("path and content required")
        }
        let url = try Workspace.resolve(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        return ["written": true, "bytes": content.utf8.count]
    }
}

final class ArtifactListTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact.list",
        summary: "列出工作区文件",
        parameters: ["subpath": "可选子目录"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let sub = params["subpath"] as? String ?? ""
        let dir = try Workspace.resolve(sub)
        let items = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return ["entries": items]
    }
}

// MARK: - 基础工具

final class PingTool: MCPTool {
    let definition = ToolDefinition(name: "ping", summary: "连通性测试")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        ["pong": true, "ts": Int(Date().timeIntervalSince1970)]
    }
}

final class DeviceInfoTool: MCPTool {
    let definition = ToolDefinition(name: "device.info", summary: "设备与应用信息")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "system": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "model": UIDevice.current.model,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-",
            "workspace": Workspace.root.path,
        ]
    }
}
