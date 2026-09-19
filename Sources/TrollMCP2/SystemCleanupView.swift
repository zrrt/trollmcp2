import SwiftUI

// v2.9.128：系统清理页（对齐 Fuck 工具箱系统清理界面）
// 存储使用卡片 + 缓存占用分类 + 快速/高级清理 Tab + 10 项开关 + 一键清理

// MARK: - 数据层

struct SystemCleanupItem: Identifiable {
    let id: String
    let label: String
    let detail: String
    let paths: [String]     // 要清空的目录（root 权限）
    let risk: Risk
    var size: Int = 0
    enum Risk { case safe, warn }
}

enum SystemCleanupEngine {
    // MARK: 存储信息
    static func storageInfo() -> [String: Any] {
        let fm = FileManager.default
        var total: Int64 = 0, free: Int64 = 0
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
            free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
        let used = max(0, total - free)
        let percent = total > 0 ? Int(Double(used) / Double(total) * 100) : 0
        let model = UIDevice.current.model
        let name = UIDevice.current.name
        let sys = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        let troll = DeviceProbe.shared.lastReport?.trollStore ?? false
        return [
            "total": total, "free": free, "used": used,
            "total_readable": AppCacheScanner.humanSize(Int(total)),
            "free_readable": AppCacheScanner.humanSize(Int(free)),
            "used_percent": percent,
            "model": "\(name) · \(model)",
            "system": sys,
            "trollstore": troll
        ]
    }

    /// 所有用户 App 数据容器路径
    private static func allContainers() -> [String] {
        AppCatalog.list().compactMap { $0.containerPath }
    }

    /// 扫描一个目录的"内容"大小（返回目录内文件总和）
    static func dirSize(_ p: String) -> Int {
        AppCacheScanner.directorySize(URL(fileURLWithPath: p))
    }

    /// 聚合扫描所有 App 容器的子目录大小
    private static func aggregateAppDirs(_ sub: String) -> Int {
        var total = 0
        for c in allContainers() {
            total += dirSize(c + "/" + sub)
        }
        return total
    }

    // MARK: 快速清理 10 项
    static func quickItems() -> [SystemCleanupItem] {
        var items: [SystemCleanupItem] = []
        let appCache = aggregateAppDirs("Library/Caches") + aggregateAppDirs("tmp")
        let appLogs = aggregateAppDirs("Library/Logs")
        let snapshots = dirSize("/var/mobile/Library/SplashBoard/Snapshots")

        items.append(SystemCleanupItem(id: "app_cache", label: "应用程序缓存",
            detail: "所有 App 的 Caches + tmp", paths: [], risk: .safe, size: appCache))
        items.append(SystemCleanupItem(id: "app_logs", label: "应用日志",
            detail: "所有 App 的 Library/Logs", paths: [], risk: .safe, size: appLogs))
        items.append(SystemCleanupItem(id: "sys_cache", label: "系统缓存文件",
            detail: "/var/mobile/Library/Caches", paths: ["/var/mobile/Library/Caches"], risk: .safe,
            size: dirSize("/var/mobile/Library/Caches")))
        items.append(SystemCleanupItem(id: "sys_logs", label: "系统日志文件",
            detail: "/var/mobile/Library/Logs", paths: ["/var/mobile/Library/Logs"], risk: .safe,
            size: dirSize("/var/mobile/Library/Logs")))
        items.append(SystemCleanupItem(id: "sys_tmp", label: "系统临时文件",
            detail: "/tmp + /var/tmp", paths: ["/tmp", "/var/tmp"], risk: .safe,
            size: dirSize("/tmp") + dirSize("/var/tmp")))
        items.append(SystemCleanupItem(id: "photo_cache", label: "照片缓存",
            detail: "PhotoData 缩略图缓存（原图不删）",
            paths: ["/var/mobile/Media/PhotoData/Thumbnails", "/var/mobile/Media/DCIM/Apple/Thumbs"],
            risk: .safe, size: dirSize("/var/mobile/Media/PhotoData/Thumbnails") + dirSize("/var/mobile/Media/DCIM/Apple/Thumbs")))
        items.append(SystemCleanupItem(id: "downloads", label: "下载文件",
            detail: "/var/mobile/Media/Downloads", paths: ["/var/mobile/Media/Downloads"], risk: .warn,
            size: dirSize("/var/mobile/Media/Downloads")))
        items.append(SystemCleanupItem(id: "snapshots", label: "启动快照",
            detail: "SplashBoard 启动截图缓存", paths: ["/var/mobile/Library/SplashBoard/Snapshots"],
            risk: .safe, size: snapshots))
        items.append(SystemCleanupItem(id: "trash", label: "垃圾箱",
            detail: "/var/mobile/.Trash", paths: ["/var/mobile/.Trash"], risk: .warn,
            size: dirSize("/var/mobile/.Trash")))
        items.append(SystemCleanupItem(id: "ota", label: "OTA 软件更新",
            detail: "已下载的系统更新包缓存",
            paths: ["/var/mobile/Library/SoftwareUpdate", "/var/mobile/Library/Assets/com_apple_MobileAsset_SoftwareUpdate"],
            risk: .warn, size: dirSize("/var/mobile/Library/SoftwareUpdate") + dirSize("/var/mobile/Library/Assets/com_apple_MobileAsset_SoftwareUpdate")))
        return items
    }

    // MARK: 高级清理
    static func advancedItems() -> [SystemCleanupItem] {
        var items: [SystemCleanupItem] = []
        let webkit = aggregateAppDirs("Library/WebKit")
        let http = aggregateAppDirs("Library/HTTPStorages")
        let safari = dirSize("/var/mobile/Library/Caches/com.apple.mobilesafari")

        items.append(SystemCleanupItem(id: "webkit", label: "WebKit 缓存",
            detail: "所有 App 的 WebKit 网页缓存", paths: [], risk: .safe, size: webkit))
        // v2.9.314：http_storage 已移除——清所有 App 的 Cookie/登录态太危险
        // items.append(SystemCleanupItem(id: "http_storage", ...))
        items.append(SystemCleanupItem(id: "safari", label: "Safari 缓存",
            detail: "Safari 网页缓存（不删书签/历史）",
            paths: ["/var/mobile/Library/Caches/com.apple.mobilesafari"], risk: .safe, size: safari))
        return items
    }

    // MARK: 执行清理
    /// 返回 (成功项, 释放字节, 失败明细)
    static func execute(_ items: [SystemCleanupItem], selected: Set<String>) -> (Int, Int, [String]) {
        var freed = 0
        var failed: [String] = []
        var ok = 0
        let im = InjectionManager.shared
        for item in items where selected.contains(item.id) {
            var itemFreed = 0
            var itemFailed = false
            // 聚合类（App 容器子目录）单独处理
            if item.id == "app_cache" || item.id == "app_logs" || item.id == "webkit" || item.id == "http_storage" {
                var sub: String
                switch item.id {
                case "app_cache": sub = "Library/Caches"  // 再加 tmp
                case "app_logs": sub = "Library/Logs"
                case "webkit": sub = "Library/WebKit"
                default: sub = "Library/HTTPStorages"
                }
                for c in allContainers() {
                    let base = c + "/" + sub
                    itemFreed += clearDirContents(base, im: im, &itemFailed)
                    if item.id == "app_cache" {
                        itemFreed += clearDirContents(c + "/tmp", im: im, &itemFailed)
                    }
                }
            } else {
                for p in item.paths {
                    itemFreed += clearDirContents(p, im: im, &itemFailed)
                }
            }
            if itemFailed { failed.append(item.label) } else { ok += 1 }
            freed += itemFreed
        }
        return (ok, freed, failed)
    }

    private static func clearDirContents(_ path: String, im: InjectionManager, _ failed: inout Bool) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return 0 }
        let before = dirSize(path)
        guard before > 0 else { return 0 }
        // v2.9.313：只删目录里的内容，不删目录本身——
        // 之前 rm -rf 整个目录再重建，会破坏 PhotoData/Caches 等系统目录的
        // 权限和结构，导致照片缩略图丢失、App 权限异常。
        // 改成遍历子项逐个删除，保留目录本身和权限。
        let (c, _) = im.runAsRoot("bash", args: ["-c", "find '\(path)' -mindepth 1 -maxdepth 1 -exec rm -rf {} +"])
        if c != 0 {
            failed = true
            return 0
        }
        return before
    }
}

// MARK: - UI

struct SystemCleanupView: View {
    @State private var storage: [String: Any] = [:]
    @State private var quickItems: [SystemCleanupItem] = []
    @State private var advancedItems: [SystemCleanupItem] = []
    @State private var selected = Set<String>()
    @State private var scanning = false
    @State private var running = false
    @State private var toast: String?
    @State private var mode: Mode = .quick

    enum Mode { case quick, advanced }

    private var allItems: [SystemCleanupItem] {
        mode == .quick ? quickItems : advancedItems
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    storageCard
                    categorySummary
                    modePicker
                    itemList
                    cleanButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("系统清理")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { toastView }
        .onAppear { if quickItems.isEmpty { startScan() } }
    }

    // MARK: 头部（大标题 + 右上快速清理）
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                Image(systemName: "externaldrive.fill.badge.timemachine")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("ui_121"))
                    .font(.title3).fontWeight(.bold)
                Text(L10n.t("ui_19"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { quickCleanAll() }) {
                Text(L10n.t("ui_58"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.tmCyan)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .disabled(running || quickItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 存储使用卡片
    private var storageCard: some View {
        HStack(spacing: 16) {
            // 环形进度
            ZStack {
                Circle()
                    .stroke(Color(.tertiarySystemFill), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat((storage["used_percent"] as? Int ?? 0)) / 100.0)
                    .stroke(
                        LinearGradient(colors: [.tmCyan, .blue], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(storage["used_percent"] as? Int ?? 0)%")
                        .font(.system(size: 20, weight: .bold))
                    Text(L10n.t("ui_54"))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 5) {
                Text(storage["model"] as? String ?? "—")
                    .font(.subheadline.weight(.semibold))
                Text("已用 \(storage["used_readable"] as? String ?? "—") / 共 \(storage["total_readable"] as? String ?? "—")")
                    .font(.caption).foregroundColor(.secondary)
                Text(storage["system"] as? String ?? "—")
                    .font(.caption).foregroundColor(.secondary)
                if storage["trollstore"] as? Bool == true {
                    Text(L10n.t("ui_9"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.tmCyan.opacity(0.14))
                        .foregroundColor(.tmCyan)
                        .clipShape(Capsule())
                }
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: 缓存占用汇总（6 类）
    private var categorySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("ui_124")).font(.subheadline.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                summaryCell("系统缓存", quickItems.first(where: { $0.id == "sys_cache" })?.size ?? 0, "internaldrive")
                summaryCell("应用缓存", quickItems.first(where: { $0.id == "app_cache" })?.size ?? 0, "app.fill")
                summaryCell("照片缓存", quickItems.first(where: { $0.id == "photo_cache" })?.size ?? 0, "photo.fill")
                summaryCell("临时文件", quickItems.first(where: { $0.id == "sys_tmp" })?.size ?? 0, "clock.fill")
                summaryCell("日志文件", (quickItems.first(where: { $0.id == "sys_logs" })?.size ?? 0) + (quickItems.first(where: { $0.id == "app_logs" })?.size ?? 0), "doc.text.fill")
                summaryCell("下载文件", quickItems.first(where: { $0.id == "downloads" })?.size ?? 0, "arrow.down.circle.fill")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func summaryCell(_ label: String, _ bytes: Int, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(.tmCyan)
            Text(AppCacheScanner.humanSize(bytes))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground))
        .cornerRadius(10)
    }

    // MARK: 快速/高级 Tab
    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach([(Mode.quick, "快速清理"), (Mode.advanced, "高级清理")], id: \.0) { m, label in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { mode = m }
                } label: {
                    Text(label)
                        .font(.subheadline.weight(mode == m ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(mode == m ? Color.tmCyan : Color.clear)
                        .foregroundColor(mode == m ? .white : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(3)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(Capsule())
    }

    // MARK: 清理项开关列表
    private var itemList: some View {
        VStack(spacing: 8) {
            ForEach(allItems) { item in
                Button {
                    toggle(item)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.risk == .safe ? "checkmark.shield" : "exclamationmark.triangle")
                            .font(.system(size: 16))
                            .foregroundColor(item.risk == .safe ? .green : .orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.subheadline)
                            Text(item.detail)
                                .font(.caption2).foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(AppCacheScanner.humanSize(item.size))
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                        Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundColor(selected.contains(item.id) ? .tmCyan : .secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: 开始清理按钮
    private var cleanButton: some View {
        Button {
            runClean()
        } label: {
            HStack {
                Spacer()
                if running {
                    ProgressView().tint(.white)
                } else {
                    Label("开始清理（\(selected.count) 项）", systemImage: "trash.fill")
                }
                Spacer()
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding(.vertical, 13)
            .background(selected.isEmpty ? Color.gray : Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(running || selected.isEmpty)
    }

    // MARK: 行为
    private func toggle(_ item: SystemCleanupItem) {
        if selected.contains(item.id) { selected.remove(item.id) }
        else {
            if item.risk == .warn {
                toast = "⚠️ \(item.label) 可能影响相关功能（下载/更新）"
            }
            selected.insert(item.id)
        }
    }

    private func startScan() {
        scanning = true
        storage = SystemCleanupEngine.storageInfo()
        DispatchQueue.global(qos: .userInitiated).async {
            let quick = SystemCleanupEngine.quickItems()
            let adv = SystemCleanupEngine.advancedItems()
            DispatchQueue.main.async {
                quickItems = quick
                advancedItems = adv
                // 默认全选安全项
                selected = Set(quick.filter { $0.risk == .safe }.map { $0.id })
                scanning = false
                toast = "扫描完成，可释放约 \(AppCacheScanner.humanSize((quick + adv).reduce(0) { $0 + $1.size }))"
            }
        }
    }

    private func quickCleanAll() {
        // 右上角快速清理：全选快速安全项直接执行
        selected = Set(quickItems.filter { $0.risk == .safe }.map { $0.id })
        runClean()
    }

    private func runClean() {
        guard !selected.isEmpty else { return }
        running = true
        let items = quickItems + advancedItems
        let sel = selected
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, freed, failed) = SystemCleanupEngine.execute(items, selected: sel)
            DispatchQueue.main.async {
                running = false
                toast = "清理完成：\(ok) 项成功，释放 \(AppCacheScanner.humanSize(freed))" + (failed.isEmpty ? "" : "；失败：\(failed.joined(separator: "、"))")
                // 重新扫描 + 更新存储
                storage = SystemCleanupEngine.storageInfo()
                let quick = SystemCleanupEngine.quickItems()
                let adv = SystemCleanupEngine.advancedItems()
                quickItems = quick
                advancedItems = adv
                selected = Set(quick.filter { $0.risk == .safe }.map { $0.id })
            }
        }
    }

    private var toastView: some View {
        Group {
            if let toast = toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(.systemGray5).opacity(0.95))
                    .clipShape(Capsule())
                    .padding(.bottom, 14)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
    }
}

// MARK: - MCP 工具（AI 也能做系统清理）

/// system.cleanup_scan：扫描设备级可清理项（快速 10 项 + 高级 3 项）
final class SystemCleanupScanTool: MCPTool {
    let definition = ToolDefinition(
        name: "system.cleanup_scan",
        summary: "扫描设备级可清理项（系统缓存/应用缓存/照片缓存/临时文件/日志/下载/启动快照/垃圾箱/OTA 更新包 + 高级 WebKit/HTTP存储/Safari），返回各项大小与风险。先 scan 再 execute",
        parameters: [:],
    verified: true,
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = ["ok": true]
        result["storage"] = SystemCleanupEngine.storageInfo()
        let all = SystemCleanupEngine.quickItems() + SystemCleanupEngine.advancedItems()
        result["items"] = all.map { i in
            ["id": i.id, "label": i.label, "detail": i.detail,
             "bytes": i.size, "bytes_readable": AppCacheScanner.humanSize(i.size),
             "risk": i.risk == .safe ? "safe" : "warn"]
        }
        let total = all.reduce(0) { $0 + $1.size }
        result["total_bytes"] = total
        result["total_readable"] = AppCacheScanner.humanSize(total)
        return result
    }
}

/// system.cleanup_execute：执行指定设备级清理项
final class SystemCleanupExecuteTool: MCPTool {
    let definition = ToolDefinition(
        name: "system.cleanup_execute",
        summary: "执行设备级清理：items 传 system.cleanup_scan 返回的 id（如 [\"app_cache\",\"sys_cache\",\"ota\"]）。risk=warn 项（下载/垃圾箱/OTA）会清空对应目录。返回释放大小与失败明细",
        parameters: ["items": "要清理的项 id 数组（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let items = params["items"] as? [String], !items.isEmpty else {
            throw MCPError.invalidParams("items required (e.g. [\"app_cache\",\"sys_cache\"])")
        }
        let all = SystemCleanupEngine.quickItems() + SystemCleanupEngine.advancedItems()
        let matched = all.filter { items.contains($0.id) }
        guard !matched.isEmpty else { return ["ok": false, "message": "没有匹配的清理项", "data": ["given": items]] }
        let (ok, freed, failed) = SystemCleanupEngine.execute(matched, selected: Set(matched.map { $0.id }))
        return [
            "ok": failed.isEmpty,
            "message": "清理完成：\(ok) 项成功，释放 \(AppCacheScanner.humanSize(freed))\(failed.isEmpty ? "" : "，失败 \(failed.joined(separator: "、"))")",
            "data": ["success": ok, "freed_bytes": freed, "freed_readable": AppCacheScanner.humanSize(freed),
                     "failed": failed, "storage_after": SystemCleanupEngine.storageInfo()]
        ]
    }
}
