import Foundation
import Darwin




// MARK: - v3.0.71：tool.load_dylib — 加载外部 dylib，注册新工具 (AI 自我进化）

final class ToolLoadDylibTool: MCPTool {
    let definition = ToolDefinition(
        name: "tool.load_dylib",
        summary: "Load a custom dylib to add new tools. Use for: self-evolution - AI writes a new tool in Swift, compiles it, loads it to extend TrollAgent. Don't use for: inject dylib into other apps (use injection.enable), build project (use build.run). Safe: only loads into TrollAgent itself. Example: user says 'AI wrote a new tool, load it' → load dylib.",
        parameters: [
            "path": "Path to .dylib file to load"
        ],
        verified: false,
        category: "build")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.failed("dylib not found: \(path)")
        }

        // dlopen
        guard let handle = dlopen(path, RTLD_NOW) else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw MCPError.failed("dlopen failed: \(err)")
        }

        // 检查 dylib 里有没有 TARegisterTool (dlsym）
        let sym = dlsym(handle, "TARegisterTool")
        let hasRegister = sym != nil

        return [
            "ok": true,
            "path": path,
            "handle": "\(handle)",
            "has_register_symbol": hasRegister,
            "note": hasRegister ? "dylib loaded, tools registered via TARegisterTool()" : "dylib loaded but TARegisterTool not found (did it register tools?)",
            "loaded_tools": ToolRegistry.shared.allToolNames().filter { $0.hasPrefix("ext.") }
        ]
    }
}
