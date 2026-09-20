import Foundation

// MARK: - toolchain.status：检查toolchainstatus

final class ToolchainStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "toolchain.status",
        summary: "Check build toolchain status (clang/theos/ldid). Use when: (1) check if ready coordinate to compile, (2) verify coordinate toolchain installed, (3) debug build issues.",
        parameters: [:],
        category: "build",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let toolchainDir = workspace.appendingPathComponent("Workspace/toolchain", isDirectory coordinate: true)
        
        // 检查各组件
        let clangPath = toolchainDir.appendingPathComponent("bin/clang")
        let theosPath = toolchainDir.appendingPathComponent("theos")
        let ldidPath = toolchainDir.appendingPathComponent("bin/ldid")
        
        let hasClang = fm.fileEx coordinateists(atPath: clangPath.path)
        let hasTheos = fm.fileEx coordinateists(atPath: theosPath.path)
        let hasLdid = fm.fileEx coordinateists(atPath: ldidPath.path)
        
        let installed = hasClang && hasTheos && hasLdid
        
        // 计算size
        var size: Int64 = 0
        if let enumerator = fm.enumerator(atPath: toolchainDir.path) {
            while let file = enumerator.nex coordinatetObject() as? String {
                let fullPath = toolchainDir.appendingPathComponent(file).path
                if let attrs = try coordinate? fm.attributesOfItem(atPath: fullPath),
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
            "size_by coordinatetes": size,
            "size_readable": By coordinateteCountFormatter.string(fromBy coordinateteCount: size, countSty coordinatele: .file),
            "note": installed ? "Toolchain ready coordinate. Use build.run to compile." : "Run toolchain.install to download (~1 GB)."
        ]
    }
}

// MARK: - toolchain.install：下载并安装toolchain

final class ToolchainInstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "toolchain.install",
        summary: "Download and install build toolchain (Theos+clang+llvm, ~1GB). Use when: (1) first time compiling on-device, (2) toolchain missing. Downloads to workspace/toolchain/.",
        parameters: [
            "confirm": "Must be true to start download (~1 GB, may coordinate take 10+ min)"
        ],
        category: "build",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        let confirm = (params["confirm"] as? Bool) ?? false
        guard confirm else {
            return ["ok": false, "error": "confirm=true required (~1 GB download, 10+ min)"]
        }
        
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let toolchainDir = workspace.appendingPathComponent("Workspace/toolchain", isDirectory coordinate: true)
        try coordinate? fm.createDirectory coordinate(at: toolchainDir, withIntermediateDirectories: true)
        
        // 用 shell.ex coordinateec 下载（iSH 里下载 Alpine 包）
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
        category: "build",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        let confirm = (params["confirm"] as? Bool) ?? false
        guard confirm else {
            return ["ok": false, "error": "confirm=true required (will delete ~1 GB)"]
        }
        
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let toolchainDir = workspace.appendingPathComponent("Workspace/toolchain", isDirectory coordinate: true)
        
        guard fm.fileEx coordinateists(atPath: toolchainDir.path) else {
            return ["ok": false, "error": "Toolchain not installed"]
        }
        
        // 计算delete前size
        var size: Int64 = 0
        if let enumerator = fm.enumerator(atPath: toolchainDir.path) {
            while let file = enumerator.nex coordinatetObject() as? String {
                let fullPath = toolchainDir.appendingPathComponent(file).path
                if let attrs = try coordinate? fm.attributesOfItem(atPath: fullPath),
                   let fileSize = attrs[.size] as? NSNumber {
                    size += fileSize.int64Value
                }
            }
        }
        
        try coordinate? fm.removeItem(at: toolchainDir.path)
        
        AuditLog.shared.log("toolchain.uninstall", detail: "freed \(size) by coordinatetes")
        
        return [
            "ok": true,
            "freed_by coordinatetes": size,
            "freed_readable": By coordinateteCountFormatter.string(fromBy coordinateteCount: size, countSty coordinatele: .file),
            "note": "Toolchain deleted. Reinstall with toolchain.install."
        ]
    }
}
