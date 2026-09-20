import Foundation

// MARK: - backup.create：backup App 数据

final class BackupCreateTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.create",
        summary: "Backup App data container to zip. Use when: (1) backup game save/chat history, (2) before reset/new device, (3) preserve App data. Saves to workspace/backups/.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)"
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
        
        // 3. 打包 zip（用 iSH 引擎执行）
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

final class BackupListTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.list",
        summary: "List all backups. Use when: (1) see available backups, (2) find backup to restore, (3) check backup history.",
        parameters: [
            "bundle_id": "Filter by App bundle_id (optional)"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory: true)
        
        guard let files = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else {
            return ["backups": [], "count": 0]
        }
        
        let bundleId = params["bundle_id"] as? String
        var backups: [[String: Any]] = []
        
        for file in files.filter({ $0.pathExtension == "zip" }).sorted(by: {
            let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return d1 > d2
        }) {
            // file名format：bundleid_timestamp.zip
            let basename = file.deletingPathExtension().lastPathComponent
            let parts = basename.split(separator: "_", maxSplits: 1)
            let bid = String(parts.first ?? "")
            let ts = Int(parts.last ?? "") ?? 0
            
            if let bid = bundleId, bid != bid { continue }
            
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            
            backups.append([
                "bundle_id": bid,
                "timestamp": ts,
                "date": ISO8601DateFormatter().string(from: date),
                "path": file.path,
                "size_bytes": size,
                "size_readable": ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            ])
        }
        
        return ["backups": backups, "count": backups.count]
    }
}

// MARK: - backup.restore：restorebackup

final class BackupRestoreTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.restore",
        summary: "Restore App data from backup. Use when: (1) restore game save/chat, (2) recover App data, (3) undo reset. Will overwrite current container!",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "backup_path": "Backup zip path (optional, use latest if not specified)",
            "confirm": "Must be true to restore (overwrites current data) (REQUIRED)"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let confirm = (params["confirm"] as? Bool) ?? false
        guard confirm else {
            return ["ok": false, "error": "confirm=true required (will overwrite current App data)"]
        }
        
        // 1. 找 App 容器
        guard let app = AppCatalog.find(bundleId) else {
            return ["ok": false, "error": "App not found: \(bundleId)"]
        }
        guard let container = app.containerPath else {
            return ["ok": false, "error": "No data container"]
        }
        
        // 2. 找backupfile
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory: true)
        
        let backupPath: URL
        if let specified = params["backup_path"] as? String {
            backupPath = URL(fileURLWithPath: specified)
        } else {
            // 找最新的
            guard let files = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey]),
                  let latest = files.filter({ $0.lastPathComponent.hasPrefix(bundleId) && $0.pathExtension == "zip" }).max(by: {
                      let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                      let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                      return d1 < d2
                  }) else {
                return ["ok": false, "error": "No backup found for \(bundleId)"]
            }
            backupPath = latest
        }
        
        guard fm.fileExists(atPath: backupPath.path) else {
            return ["ok": false, "error": "Backup file not found: \(backupPath.path)"]
        }
        
        // 3. 先backup当前数据（防止restore失败）
        let currentBackupPath = backupDir.appendingPathComponent("pre_restore_\(bundleId)_\(Int(Date().timeIntervalSince1970)).zip")
        let containerParent = (container as NSString).deletingLastPathComponent
        let containerName = (container as NSString).lastPathComponent
        
        // 3. 先 zip 当前数据（iSH）
        _ = ISHEngine.exec("cd \(containerParent) && zip -r -y \(currentBackupPath.path) \(containerName) 2>&1", timeout: 120)
        
        // 4. delete旧容器
        try? fm.removeItem(atPath: container)
        
        // 5. 解压backup（iSH）
        _ = ISHEngine.exec("unzip -o \(backupPath.path) -d \(containerParent) 2>&1", timeout: 120)
        
        guard fm.fileExists(atPath: container) else {
            // restore失败，从 pre_restore restore
            _ = ISHEngine.exec("unzip -o \(currentBackupPath.path) -d \(containerParent) 2>&1", timeout: 120)
            return ["ok": false, "error": "Restore failed, rolled back from pre_restore"]
        }
        
        AuditLog.shared.log("backup.restore", detail: "\(bundleId) from \(backupPath.lastPathComponent)")
        
        return [
            "ok": true,
            "bundle_id": bundleId,
            "restored_from": backupPath.lastPathComponent,
            "pre_restore_backup": currentBackupPath.lastPathComponent,
            "container_path": container,
            "note": "Restart App to apply"
        ]
    }
}


// MARK: - backup.device_fake：backupdevice伪装配置

final class BackupDeviceFakeTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.device_fake",
        summary: "Backup device spoofing config (fake_device.json). Use when: (1) save fake device setup, (2) restore spoofing later, (3) clone setup to another App. Saves to workspace/backups/.",
        parameters: [
            "name": "Backup name (optional, default: device_fake_<timestamp>)"
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

final class BackupRestoreDeviceFakeTool: MCPTool {
    let definition = ToolDefinitioname: "backup.restore_device_fake",
        summary: "Restore device spoofing config from backup. Use when: (1) re-apply saved fake device setup, (2) restore spoofing after reset, (3) clone config. Will overwrite current fake_device.json!",
        parameters: [
            "backup_name": "Backup name (optional, use latest if not specified)",
            "confirm": "Must be true to overwrite current config (REQUIRED)"
        ]"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let confirm = (params["confirm"] as? Bool) ?? false
        guard confirm else {
            return ["ok": false, "error": "confirm=true required (will overwrite current fake_device.json)"]
        }
        
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory: true)
        
        // 找backupfile
        let backupPath: URL
        if let specified = params["backup_name"] as? String {
            backupPath = backupDir.appendingPathComponent("\(specified).json")
        } else {
            // 找最新的 device_fake backup
            guard let files = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey]),
                  let latest = files.filter({ $0.lastPathComponent.hasPrefix("device_fake_") && $0.pathExtension == "json" }).max(by: {
                      let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                      let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                      return d1 < d2
                  }) else {
                return ["ok": false, "error": "No device_fake backup found"]
            }
            backupPath = latest
        }
        
        guard fm.fileExists(atPath: backupPath.path) else {
            return ["ok": false, "error": "Backup not found: \(backupPath.path)"]
        }
        
        // restore
        let fakeConfigPath = workspace.appendingPathComponent("Workspace/fake_device.json")
        try? fm.removeItem(at: fakeConfigPath)
        try? fm.copyItem(at: backupPath, to: fakeConfigPath)
        
        AuditLog.shared.log("backup.restore_device_fake", detail: backupPath.lastPathComponent)
        
        return [
            "ok": true,
            "restored_from": backupPath.lastPathComponent,
            "config_path": fakeConfigPath.path,
            "note": "Restart App to apply"
        ]
    }
}


// MARK: - backup.full_new_device：一键新机前整体backup

final class BackupFullNewDeviceTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.full_new_device",
        summary: "Full backup before new device reset: App data + device spoofing config + keychain. Use when: (1) before one-click new device, (2) migrating to new device, (3) full system backup. Creates a single archive with everything.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "include_keychain": "Include keychain backup (default true, may require special permissions)"
        ],
        verified: false)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let includeKeychain = (params["include_keychain"] as? Bool) ?? true
        
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let archiveName = "newdevice_\(bundleId)_\(timestamp)"
        let archiveDir = backupDir.appendingPathComponent(archiveName)
        try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        
        var steps: [[String: Any]] = []
        
        // 1. backup App 数据
        let appBackupTool = BackupCreateTool()
        let appResult = try appBackupTool.invoke(["bundle_id": bundleId])
        steps.append(["step": "app_data", "ok": (appResult["ok"] as? Bool) ?? false, "path": appResult["backup_path"] ?? ""])
        
        // 复制到整体backupdirectory
        if let appPath = appResult["backup_path"] as? String {
            try? fm.copyItem(atPath: appPath, toPath: archiveDir.appendingPathComponent("app_data.zip").path)
        }
        
        // 2. backupdevice伪装配置
        let fakeBackupTool = BackupDeviceFakeTool()
        let fakeResult = try fakeBackupTool.invoke([:])
        steps.append(["step": "device_fake", "ok": (fakeResult["ok"] as? Bool) ?? false, "path": fakeResult["backup_path"] ?? ""])
        
        if let fakePath = fakeResult["backup_path"] as? String {
            try? fm.copyItem(atPath: fakePath, toPath: archiveDir.appendingPathComponent("device_fake.json").path)
        }
        
        // 3. 钥匙串backup（TODO：实际导出逻辑）
        if includeKeychain {
            steps.append(["step": "keychain", "ok": false, "note": "TODO: keychain export not implemented yet"])
        }
        
        // 4. 打包成单个 zip（iSH）
        let archiveZipPath = backupDir.appendingPathComponent("\(archiveName).zip")
        _ = ISHEngine.exec("cd \(backupDir.path) && zip -r -y \(archiveZipPath.path) \(archiveName) 2>&1", timeout: 120)
        
        // 计算size
        let attrs = try? fm.attributesOfItem(atPath: archiveZipPath.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        
        AuditLog.shared.log("backup.full_new_device", detail: "\(bundleId) → \(archiveName).zip (\(size) bytes)")
        
        return [
            "ok": true,
            "bundle_id": bundleId,
            "archive_name": archiveName,
            "archive_path": archiveZipPath.path,
            "archive_size_bytes": size,
            "archive_size_readable": ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
            "steps": steps,
            "note": "Full backup created. Restore with restore.full_new_device (TODO)"
        ]
    }
}
