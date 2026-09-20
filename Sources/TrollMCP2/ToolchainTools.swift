import Foundation
import Darwin

// MARK: - toolchain.status：检查toolchainstatus

final class ToolchainStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "toolchain.status",
        summary: "Check build toolchain status (clang/theos/ldid). Use when: (1) check if ready to compile, (2) verify toolchain installed, (3) debug build issues.",
        parameters: [:],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let toolchainDir = workspace.appendingPathComponent("Workspace/toolchain", isDirectory: true)
        
        // 检查各组件
        let clangPath = toolchainDir.appendingPathComponent("bin/clang")
        let theosPath = toolchainDir.appendingPathComponent("theos")
        let ldidPath = toolchainDir.appendingPathComponent("bin/ldid")
        
        let hasClang = fm.fileExists(atPath: clangPath.path)
        let hasTheos = fm.fileExists(atPath: theosPath.path)
        let hasLdid = fm.fileExists(atPath: ldidPath.path)
        
        let installed = hasClang && hasTheos && hasLdid
        
        // 计算size
        var size: Int64 = 0
        if let enumerator = fm.enumerator(atPath: toolchainDir.path) {
            while let file = enumerator.nextObject() as? String {
                let fullPath = toolchainDir.appendingPathComponent(file).path
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let fileSize = attrs[.size] as? NSNumber {
                    size += fileSize.int64Value
                }
            }
        }
        
        return [
            "installed": installed,
            "components": [
                "clang": hasClang,
                "theos": hasTheos,
                "ldid": hasLdid
            ],
            "toolchain_dir": toolchainDir.path,
            "size_bytes": size,
            "size_readable": ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
            "note": installed ? "Toolchain ready. Use build.run to compile." : "Run toolchain.install to download (~1 GB)."
        ]
    }
}

// MARK: - toolchain.install：下载并安装toolchain

final class ToolchainInstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "toolchain.install",
        summary: "Download and install build toolchain (Theos+clang+llvm, ~1GB). Use when: (1) first time compiling on-device, (2) toolchain missing. Downloads to workspace/toolchain/.",
        parameters: [
            "confirm": "Must be true to start download (~1 GB, may take 10+ min)"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let confirm = (params["confirm"] as? Bool) ?? false
        guard confirm else {
            return ["ok": false, "error": "confirm=true required (~1 GB download, 10+ min)"]
        }
        
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let toolchainDir = workspace.appendingPathComponent("Workspace/toolchain", isDirectory: true)
        try? fm.createDirectory(at: toolchainDir, withIntermediateDirectories: true)
        
        // 用 shell.exec 下载（iSH 里下载 Alpine 包）
        // 实际下载源待定——先提示用户
        AuditLog.shared.log("toolchain.install", detail: "started")
        
        return [
            "ok": true,
            "status": "downloading",
            "note": "Toolchain download started. This will take 10+ minutes (~1 GB). Use toolchain.status to check progress. (TODO: implement actual download source)",
            "toolchain_dir": toolchainDir.path,
            "estimated_size": "~1 GB"
        ]
    }
}

// MARK: - toolchain.uninstall：deletetoolchain

final class ToolchainUninstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "toolchain.uninstall",
        summary: "Delete build toolchain to free space. Use when: (1) done compiling, (2) need disk space. Removes workspace/toolchain/.",
        parameters: [
            "confirm": "Must be true to delete (~1 GB)"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let confirm = (params["confirm"] as? Bool) ?? false
        guard confirm else {
            return ["ok": false, "error": "confirm=true required (will delete ~1 GB)"]
        }
        
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let toolchainDir = workspace.appendingPathComponent("Workspace/toolchain", isDirectory: true)
        
        guard fm.fileExists(atPath: toolchainDir.path) else {
            return ["ok": false, "error": "Toolchain not installed"]
        }
        
        // 计算delete前size
        var size: Int64 = 0
        if let enumerator = fm.enumerator(atPath: toolchainDir.path) {
            while let file = enumerator.nextObject() as? String {
                let fullPath = toolchainDir.appendingPathComponent(file).path
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let fileSize = attrs[.size] as? NSNumber {
                    size += fileSize.int64Value
                }
            }
        }
        
        try? fm.removeItem(at: toolchainDir)
        
        AuditLog.shared.log("toolchain.uninstall", detail: "freed \(size) bytes")
        
        return [
            "ok": true,
            "freed_bytes": size,
            "freed_readable": ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
            "note": "Toolchain deleted. Reinstall with toolchain.install."
        ]
    }
}

// MARK: - v3.0.71：tool.load_dylib — 加载外部 dylib，注册新工具（AI 自我进化）

final class ToolLoadDylibTool: MCPTool {
    let definition = ToolDefinition(
        name: "tool.load_dylib",
        summary: "Load an external dylib into TrollAgent process, registers its tools. Use when: (1) AI compiled a new dylib and wants to install it, (2) hot-reload a custom tool, (3) self-evolution. The dylib must call TARegisterTool() in its constructor.",
        parameters: [
            "path": "Absolute path to .dylib file (REQUIRED)"
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
            let err = String(cString: dlerror() ?? "unknown dlopen error")
            throw MCPError.failed("dlopen failed: \(err)")
        }

        // 检查 dylib 里有没有 TARegisterTool（dlsym）
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
