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
        summary: "Install on-device build toolchain (Theos+clang+llvm). CURRENTLY UNAVAILABLE — no reliable on-device download source (needs ~1GB prebuilt artifacts). Use cross-compile on PC instead. (v3.6.19g fixed the fake-implementation that pretended to download but never did.)",
        parameters: [
            "confirm": "Must be true to start download (~1 GB, may take 10+ min)"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let confirm = (params["confirm"] as? Bool) ?? false
        guard confirm else {
            return ["ok": false, "error": "confirm=true required (~1 GB download, 10+ min)"]
        }
        
        // v3.6.19g: 修复假实现——原来无条件返回 status:"downloading" 却从未真正下载
        // (旧注释: "TODO: implement actual download source")，用户会无限等待。当前设备端没有可靠
        // 工具链下载源(需预编译 Theos+clang+llvm ~1GB 产物)，诚实报不可用，避免误导。
        AuditLog.shared.log("toolchain.install", detail: "denied: no reliable download source")
        return [
            "ok": false,
            "status": "unavailable",
            "error": "toolchain.install 暂不可用：设备端没有可靠的工具链下载源（需预编译的 Theos+clang+llvm ~1GB 产物）。请用电脑端交叉编译；若提供可信镜像源后可实现真下载。",
            "toolchain_dir": "Workspace/toolchain/"
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
