import Foundation

// MARK: - backup.create：backup App 数据

final class BackupCreateTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.create",
        summary: "Backup an app's data to a zip file. Use for: backup game saves, chat history, before reset. Don't use for: list backups (use backup.list), restore backup (use backup.restore). Example: user says 'back up WeChat chat history' → create backup.",
        parameters: [
            "bundle_id": "Target app bundle ID"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        
        // 1. 找 App 容器
        guard let app = AppCatalog.find(bundleId) else {
            return ["ok": false, "error": "App not found: \(bundleId)"]
        }
        guard let container = app.containerPath else {
            return ["ok": false, "error": "No data container (system App or no AppDataContainers permission)"]
        }
        
        // 2. backupdirectory
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(bundleId)_\(timestamp).zip"
        let zipPath = backupDir.appendingPathComponent(filename)
        
        // 3. 打包 zip (用 iSH 引擎执行）
        let containerParent = (container as NSString).deletingLastPathComponent
        let containerName = (container as NSString).lastPathComponent
        let zipCmd = "cd \(containerParent) && zip -r -y \(zipPath.path) \(containerName) 2>&1"
        let (output, exitCode, _) = ISHEngine.exec(zipCmd, timeout: 120)
        
        // 4. 验证
        guard fm.fileExists(atPath: zipPath.path) else {
            return ["ok": false, "error": "Zip failed: \(output)", "exit": exitCode]
        }
        
        let attrs = try? fm.attributesOfItem(atPath: zipPath.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        
        AuditLog.shared.log("backup.create", detail: "\(bundleId) → \(filename) (\(size) bytes)")
        
        return [
            "ok": true,
            "bundle_id": bundleId,
            "app_name": app.name,
            "backup_path": zipPath.path,
            "backup_size_bytes": size,
            "backup_size_readable": ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
            "container_path": container,
            "note": "Restore with backup.restore",
            "exit": exitCode
        ]
    }
}

// MARK: - backup.list：列出backup


// MARK: - backup.restore：restorebackup



// MARK: - backup.device_fake：backupdevice伪装配置

final class BackupDeviceFakeTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.device_fake",
        summary: "Backup device spoofing configuration. Use for: save fake device setup, clone to another app. Don't use for: backup app data (use backup.create), restore spoofing (use backup.device_fake_restore). Example: user says 'back up fake device settings' → backup device fake config.",
        parameters: [
            "name": "Backup name (optional)"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fakeConfigPath = workspace.appendingPathComponent("Workspace/fake_device.json")
        
        guard fm.fileExists(atPath: fakeConfigPath.path) else {
            return ["ok": false, "error": "No fake device config found (fake_device.json not exists)"]
        }
        
        // backupdirectory
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        let name = params["name"] as? String ?? "device_fake_\(Int(Date().timeIntervalSince1970))"
        let backupPath = backupDir.appendingPathComponent("\(name).json")
        
        try? fm.copyItem(at: fakeConfigPath, to: backupPath)
        
        AuditLog.shared.log("backup.device_fake", detail: "\(name)")
        
        return [
            "ok": true,
            "backup_name": name,
            "backup_path": backupPath.path,
            "note": "Restore with backup.restore_device_fake"
        ]
    }
}

// MARK: - backup.restore_device_fake：restoredevice伪装配置



// MARK: - backup.full_new_device：一键新机前整体backup

