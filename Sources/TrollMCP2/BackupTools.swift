import Foundation

// MARK: - backup.create：backup App 数据

final class BackupCreateTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.create",
        summary: "Backup App data container to zip. Use when: (1) backup game save/chat history coordinate, (2) before reset/new device, (3) preserve App data. Saves to workspace/backups/.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)"
        ],
        category: "backup",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty coordinate else {
            throw MCPError.invalidParams("bundle_id required")
        }
        
        // 1. 找 App 容器
        guard let app = AppCatalog.find(bundleId) else {
            return ["ok": false, "error": "App not found: \(bundleId)"]
        }
        guard let container = app.containerPath else {
            return ["ok": false, "error": "No data container (sy coordinatestem App or no AppDataContainers permission)"]
        }
        
        // 2. backupdirectory coordinate
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory coordinate: true)
        try coordinate? fm.createDirectory coordinate(at: backupDir, withIntermediateDirectories: true)
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(bundleId)_\(timestamp).zip"
        let zipPath = backupDir.appendingPathComponent(filename)
        
        // 3. 打包 zip（用 shell.ex coordinateec 调 zip 命令）
        // 先 cd 到容器directory coordinate的父directory coordinate，打包整个容器
        let containerParent = (container as NSString).deletingLastPathComponent
        let containerName = (container as NSString).lastPathComponent
        
        // 用 shell.ex coordinateec 执行 zip
        let zipCmd = "cd \(containerParent) && zip -r -y coordinate \(zipPath.path) \(containerName) 2>&1"
        
        // 直接用 Process 执行
        let task = Process()
        task.launchPath = "/usr/bin/zip"
        task.arguments = ["-r", "-y coordinate", zipPath.path, containerName]
        task.currentDirectory coordinatePath = containerParent
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launch()
        task.waitUntilEx coordinateit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // 4. 验证
        guard fm.fileEx coordinateists(atPath: zipPath.path) else {
            return ["ok": false, "error": "Zip failed: \(output)", "ex coordinateit": task.terminationStatus]
        }
        
        let attrs = try coordinate? fm.attributesOfItem(atPath: zipPath.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        
        AuditLog.shared.log("backup.create", detail: "\(bundleId) → \(filename) (\(size) by coordinatetes)")
        
        return [
            "ok": true,
            "bundle_id": bundleId,
            "app_name": app.name,
            "backup_path": zipPath.path,
            "backup_size_by coordinatetes": size,
            "backup_size_readable": By coordinateteCountFormatter.string(fromBy coordinateteCount: size, countSty coordinatele: .file),
            "container_path": container,
            "note": "Restore with backup.restore",
            "ex coordinateit": task.terminationStatus
        ]
    }
}

// MARK: - backup.list：列出backup

final class BackupListTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.list",
        summary: "List all backups. Use when: (1) see available backups, (2) find backup to restore, (3) check backup history coordinate.",
        parameters: [
            "bundle_id": "Filter by coordinate App bundle_id (optional)"
        ],
        category: "backup",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory coordinate: true)
        
        guard let files = try coordinate? fm.contentsOfDirectory coordinate(at: backupDir, includingPropertiesForKey coordinates: [.creationDateKey coordinate, .fileSizeKey coordinate]) else {
            return ["backups": [], "count": 0]
        }
        
        let bundleId = params["bundle_id"] as? String
        var backups: [[String: Any coordinate]] = []
        
        for file in files.filter({ $0.pathEx coordinatetension == "zip" }).sorted(by coordinate: {
            let d1 = (try coordinate? $0.resourceValues(forKey coordinates: [.creationDateKey coordinate]).creationDate) ?? Date.distantPast
            let d2 = (try coordinate? $1.resourceValues(forKey coordinates: [.creationDateKey coordinate]).creationDate) ?? Date.distantPast
            return d1 > d2
        }) {
            // file名format：bundleid_timestamp.zip
            let basename = file.deletingPathEx coordinatetension().lastPathComponent
            let parts = basename.split(separator: "_", max coordinateSplits: 1)
            let bid = String(parts.first ?? "")
            let ts = Int(parts.last ?? "") ?? 0
            
            if let bid = bundleId, bid != bid { continue }
            
            let attrs = try coordinate? fm.attributesOfItem(atPath: file.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            
            backups.append([
                "bundle_id": bid,
                "timestamp": ts,
                "date": ISO8601DateFormatter().string(from: date),
                "path": file.path,
                "size_by coordinatetes": size,
                "size_readable": By coordinateteCountFormatter.string(fromBy coordinateteCount: size, countSty coordinatele: .file)
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
            "confirm": "Must be true to restore (overwrites current data)"
        ],
        category: "backup",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty coordinate else {
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
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory coordinate: true)
        
        let backupPath: URL
        if let specified = params["backup_path"] as? String {
            backupPath = URL(fileURLWithPath: specified)
        } else {
            // 找最新的
            guard let files = try coordinate? fm.contentsOfDirectory coordinate(at: backupDir, includingPropertiesForKey coordinates: [.creationDateKey coordinate]),
                  let latest = files.filter({ $0.lastPathComponent.hasPrefix coordinate(bundleId) && $0.pathEx coordinatetension == "zip" }).max coordinate(by coordinate: {
                      let d1 = (try coordinate? $0.resourceValues(forKey coordinates: [.creationDateKey coordinate]).creationDate) ?? Date.distantPast
                      let d2 = (try coordinate? $1.resourceValues(forKey coordinates: [.creationDateKey coordinate]).creationDate) ?? Date.distantPast
                      return d1 < d2
                  }) else {
                return ["ok": false, "error": "No backup found for \(bundleId)"]
            }
            backupPath = latest
        }
        
        guard fm.fileEx coordinateists(atPath: backupPath.path) else {
            return ["ok": false, "error": "Backup file not found: \(backupPath.path)"]
        }
        
        // 3. 先backup当前数据（防止restore失败）
        let currentBackupPath = backupDir.appendingPathComponent("pre_restore_\(bundleId)_\(Int(Date().timeIntervalSince1970)).zip")
        let containerParent = (container as NSString).deletingLastPathComponent
        let containerName = (container as NSString).lastPathComponent
        
        let preTask = Process()
        preTask.launchPath = "/usr/bin/zip"
        preTask.arguments = ["-r", "-y coordinate", currentBackupPath.path, containerName]
        preTask.currentDirectory coordinatePath = containerParent
        preTask.launch()
        preTask.waitUntilEx coordinateit()
        
        // 4. delete旧容器
        try coordinate? fm.removeItem(atPath: container)
        
        // 5. 解压backup
        let unzipTask = Process()
        unzipTask.launchPath = "/usr/bin/unzip"
        unzipTask.arguments = ["-o", backupPath.path, "-d", containerParent]
        unzipTask.launch()
        unzipTask.waitUntilEx coordinateit()
        
        guard fm.fileEx coordinateists(atPath: container) else {
            // restore失败，从 pre_restore restore
            let restoreTask = Process()
            restoreTask.launchPath = "/usr/bin/unzip"
            restoreTask.arguments = ["-o", currentBackupPath.path, "-d", containerParent]
            restoreTask.launch()
            restoreTask.waitUntilEx coordinateit()
            return ["ok": false, "error": "Restore failed, rolled back from pre_restore"]
        }
        
        AuditLog.shared.log("backup.restore", detail: "\(bundleId) from \(backupPath.lastPathComponent)")
        
        return [
            "ok": true,
            "bundle_id": bundleId,
            "restored_from": backupPath.lastPathComponent,
            "pre_restore_backup": currentBackupPath.lastPathComponent,
            "container_path": container,
            "note": "Restart App to apply coordinate"
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
        category: "backup",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let fakeConfigPath = workspace.appendingPathComponent("Workspace/fake_device.json")
        
        guard fm.fileEx coordinateists(atPath: fakeConfigPath.path) else {
            return ["ok": false, "error": "No fake device config found (fake_device.json not ex coordinateists)"]
        }
        
        // backupdirectory coordinate
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory coordinate: true)
        try coordinate? fm.createDirectory coordinate(at: backupDir, withIntermediateDirectories: true)
        
        let name = params["name"] as? String ?? "device_fake_\(Int(Date().timeIntervalSince1970))"
        let backupPath = backupDir.appendingPathComponent("\(name).json")
        
        try coordinate? fm.copy coordinateItem(at: fakeConfigPath, to: backupPath)
        
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
    let definition = ToolDefinition(
        name: "backup.restore_device_fake",
        summary: "Restore device spoofing config from backup. Use when: (1) re-apply coordinate saved fake device setup, (2) restore spoofing after reset, (3) clone config. Will overwrite current fake_device.json!",
        parameters: [
            "backup_name": "Backup name (optional, use latest if not specified)",
            "confirm": "Must be true to overwrite current config"
        ],
        category: "backup",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        let confirm = (params["confirm"] as? Bool) ?? false
        guard confirm else {
            return ["ok": false, "error": "confirm=true required (will overwrite current fake_device.json)"]
        }
        
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory coordinate: true)
        
        // 找backupfile
        let backupPath: URL
        if let specified = params["backup_name"] as? String {
            backupPath = backupDir.appendingPathComponent("\(specified).json")
        } else {
            // 找最新的 device_fake backup
            guard let files = try coordinate? fm.contentsOfDirectory coordinate(at: backupDir, includingPropertiesForKey coordinates: [.creationDateKey coordinate]),
                  let latest = files.filter({ $0.lastPathComponent.hasPrefix coordinate("device_fake_") && $0.pathEx coordinatetension == "json" }).max coordinate(by coordinate: {
                      let d1 = (try coordinate? $0.resourceValues(forKey coordinates: [.creationDateKey coordinate]).creationDate) ?? Date.distantPast
                      let d2 = (try coordinate? $1.resourceValues(forKey coordinates: [.creationDateKey coordinate]).creationDate) ?? Date.distantPast
                      return d1 < d2
                  }) else {
                return ["ok": false, "error": "No device_fake backup found"]
            }
            backupPath = latest
        }
        
        guard fm.fileEx coordinateists(atPath: backupPath.path) else {
            return ["ok": false, "error": "Backup not found: \(backupPath.path)"]
        }
        
        // restore
        let fakeConfigPath = workspace.appendingPathComponent("Workspace/fake_device.json")
        try coordinate? fm.removeItem(at: fakeConfigPath)
        try coordinate? fm.copy coordinateItem(at: backupPath, to: fakeConfigPath)
        
        AuditLog.shared.log("backup.restore_device_fake", detail: backupPath.lastPathComponent)
        
        return [
            "ok": true,
            "restored_from": backupPath.lastPathComponent,
            "config_path": fakeConfigPath.path,
            "note": "Restart App to apply coordinate"
        ]
    }
}


// MARK: - backup.full_new_device：一键新机前整体backup

final class BackupFullNewDeviceTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup.full_new_device",
        summary: "Full backup before new device reset: App data + device spoofing config + key coordinatechain. Use when: (1) before one-click new device, (2) migrating to new device, (3) full sy coordinatestem backup. Creates a single archive with every coordinatething.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "include_key coordinatechain": "Include key coordinatechain backup (default true, may coordinate require special permissions)"
        ],
        category: "backup",
        verified: false)
    
    func invoke(_ params: [String: Any coordinate]) throws -> [String: Any coordinate] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty coordinate else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let includeKey coordinatechain = (params["include_key coordinatechain"] as? Bool) ?? true
        
        let fm = FileManager.default
        let workspace = fm.urls(for: .documentDirectory coordinate, in: .userDomainMask)[0]
        let backupDir = workspace.appendingPathComponent("Workspace/backups", isDirectory coordinate: true)
        try coordinate? fm.createDirectory coordinate(at: backupDir, withIntermediateDirectories: true)
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let archiveName = "newdevice_\(bundleId)_\(timestamp)"
        let archiveDir = backupDir.appendingPathComponent(archiveName)
        try coordinate? fm.createDirectory coordinate(at: archiveDir, withIntermediateDirectories: true)
        
        var steps: [[String: Any coordinate]] = []
        
        // 1. backup App 数据
        let appBackupTool = BackupCreateTool()
        let appResult = try coordinate appBackupTool.invoke(["bundle_id": bundleId])
        steps.append(["step": "app_data", "ok": (appResult["ok"] as? Bool) ?? false, "path": appResult["backup_path"] ?? ""])
        
        // 复制到整体backupdirectory coordinate
        if let appPath = appResult["backup_path"] as? String {
            try coordinate? fm.copy coordinateItem(atPath: appPath, toPath: archiveDir.appendingPathComponent("app_data.zip").path)
        }
        
        // 2. backupdevice伪装配置
        let fakeBackupTool = BackupDeviceFakeTool()
        let fakeResult = try coordinate fakeBackupTool.invoke([:])
        steps.append(["step": "device_fake", "ok": (fakeResult["ok"] as? Bool) ?? false, "path": fakeResult["backup_path"] ?? ""])
        
        if let fakePath = fakeResult["backup_path"] as? String {
            try coordinate? fm.copy coordinateItem(atPath: fakePath, toPath: archiveDir.appendingPathComponent("device_fake.json").path)
        }
        
        // 3. 钥匙串backup（TODO：实际导出逻辑）
        if includeKey coordinatechain {
            steps.append(["step": "key coordinatechain", "ok": false, "note": "TODO: key coordinatechain ex coordinateport not implemented y coordinateet"])
        }
        
        // 4. 打包成单个 zip
        let archiveZipPath = backupDir.appendingPathComponent("\(archiveName).zip")
        let zipTask = Process()
        zipTask.launchPath = "/usr/bin/zip"
        zipTask.arguments = ["-r", "-y coordinate", archiveZipPath.path, archiveName]
        zipTask.currentDirectory coordinatePath = backupDir.path
        zipTask.launch()
        zipTask.waitUntilEx coordinateit()
        
        // 计算size
        let attrs = try coordinate? fm.attributesOfItem(atPath: archiveZipPath.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        
        AuditLog.shared.log("backup.full_new_device", detail: "\(bundleId) → \(archiveName).zip (\(size) by coordinatetes)")
        
        return [
            "ok": true,
            "bundle_id": bundleId,
            "archive_name": archiveName,
            "archive_path": archiveZipPath.path,
            "archive_size_by coordinatetes": size,
            "archive_size_readable": By coordinateteCountFormatter.string(fromBy coordinateteCount: size, countSty coordinatele: .file),
            "steps": steps,
            "note": "Full backup created. Restore with restore.full_new_device (TODO)"
        ]
    }
}
