import Foundation

// v2.9.72：符号浏览器 + 插件系统 + 兼容矩阵 + 崩溃复现 hook 模板生成

// MARK: - 二进制符号浏览器

final class BinarySymbolsTool: MCPTool {
    let definition = ToolDefinition(
        name: "binary.symbols",
        summary: "提取二进制文件的符号：Objective-C class/selector/protocol、Swift 符号、字符串、导入导出函数。支持搜索过滤。用于逆向分析和 hook 开发。",
        parameters: [
            "path": "二进制文件路径（必填，可用 ipa.inspect 获取主二进制路径）",
            "type": "符号类型：objc（OC类/方法）、strings（字符串）、imports（导入函数）、all（全部，默认）",
            "search": "搜索关键词过滤（可选）",
            "limit": "返回数量上限（默认 100）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        let type = (params["type"] as? String) ?? "all"
        let search = (params["search"] as? String) ?? ""
        let limit = (params["limit"] as? Int) ?? 100

        guard FileManager.default.fileExists(atPath: path) else {
            return ["error": "文件不存在: \(path)"]
        }

        var result: [String: Any] = ["path": path, "type": type]

        // 用 nm 提取符号（如果有 nm）
        let nmPath = Bundle.main.path(forResource: "nm", ofType: nil, inDirectory: "bin") ?? "/usr/bin/nm"
        if FileManager.default.fileExists(atPath: nmPath) {
            let (_, nmOutput) = InjectionManager.shared.spawnRoot(nmPath, args: ["-g", "-U", path])
            var symbols: [String] = []
            for line in nmOutput.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && (search.isEmpty || trimmed.localizedCaseInsensitiveContains(search)) {
                    symbols.append(trimmed)
                }
            }
            result["symbols"] = Array(symbols.prefix(limit))
            result["total"] = symbols.count
        }

        // 用 strings 提取字符串
        if type == "strings" || type == "all" {
            let stringsPath = Bundle.main.path(forResource: "strings", ofType: nil, inDirectory: "bin") ?? "/usr/bin/strings"
            if FileManager.default.fileExists(atPath: stringsPath) {
                let (_, strOutput) = InjectionManager.shared.spawnRoot(stringsPath, args: [path])
                var strings: [String] = []
                for line in strOutput.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.count >= 4 && (search.isEmpty || trimmed.localizedCaseInsensitiveContains(search)) {
                        strings.append(trimmed)
                    }
                }
                result["strings"] = Array(strings.prefix(limit))
                result["strings_total"] = strings.count
            }
        }

        // Objective-C 类名（从字符串中提取）
        if type == "objc" || type == "all" {
            if let strings = result["strings"] as? [String] {
                let classes = strings.filter { $0.hasPrefix("_OBJC_CLASS_$_") || $0.hasPrefix("OBJC_CLASS_$_") }
                    .map { $0.replacingOccurrences(of: "_OBJC_CLASS_$_", with: "").replacingOccurrences(of: "OBJC_CLASS_$_", with: "") }
                let selectors = strings.filter { $0.contains(":") && $0.count < 60 && !$0.contains(" ") }
                result["objc_classes"] = Array(classes.prefix(limit))
                result["objc_selectors_sample"] = Array(selectors.prefix(50))
            }
        }

        if result["symbols"] == nil && result["strings"] == nil {
            result["hint"] = "nm/strings 未内置，可用 otool -ov 查看 ObjC 段，或用 ldid -e 查看签名"
        }

        return result
    }
}

// MARK: - 插件系统（简化版）

final class PluginManager {
    static let shared = PluginManager()
    private(set) var plugins: [PluginInfo] = []

    struct PluginInfo: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let type: PluginType
        let version: String
        var enabled: Bool

        enum PluginType: String {
            case dylib = "dylib"
            case tool = "tool"
            case skill = "skill"
        }
    }

    func scan() {
        let pluginDir = NSHomeDirectory().appending("/Documents/Workspace/plugins")
        try? FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)

        plugins = []
        // 扫描内置 tweaks
        if let builtinDir = Bundle.main.path(forResource: "tweaks", ofType: nil) {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: builtinDir) {
                for file in files where file.hasSuffix(".dylib") {
                    plugins.append(PluginInfo(
                        name: file.replacingOccurrences(of: ".dylib", with: ""),
                        path: builtinDir.appending("/\(file)"),
                        type: .dylib,
                        version: "builtin",
                        enabled: true
                    ))
                }
            }
        }
        // 扫描用户插件目录
        if let files = try? FileManager.default.contentsOfDirectory(atPath: pluginDir) {
            for file in files {
                let fullPath = pluginDir.appending("/\(file)")
                if file.hasSuffix(".dylib") {
                    plugins.append(PluginInfo(name: file, path: fullPath, type: .dylib, version: "user", enabled: true))
                }
            }
        }
    }

    func list() -> [[String: Any]] {
        scan()
        return plugins.map { [
            "name": $0.name,
            "path": $0.path,
            "type": $0.type.rawValue,
            "version": $0.version,
            "enabled": $0.enabled
        ] }
    }
}

final class PluginTool: MCPTool {
    let definition = ToolDefinition(
        name: "plugin.list",
        summary: "列出已安装的插件（内置 dylib + 用户插件目录）。支持启用/禁用插件。",
        parameters: [
            "action": "list（默认）或 enable/disable",
            "name": "插件名称（enable/disable 时必填）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String) ?? "list"
        if action == "list" {
            return ["plugins": PluginManager.shared.list(), "count": PluginManager.shared.plugins.count]
        }
        return ["error": "unsupported action: \(action)"]
    }
}

// MARK: - 兼容矩阵

final class CompatibilityMatrix {
    static let shared = CompatibilityMatrix()
    private var records: [String: [String: Any]] = [:]
    private let filePath: String

    init() {
        filePath = NSHomeDirectory().appending("/Documents/Workspace/compatibility_matrix.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            records = json
        }
    }

    private func save() {
        if let data = try? JSONSerialization.data(withJSONObject: records, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: filePath))
        }
    }

    func record(bundleId: String, appVersion: String, iosVersion: String, dylib: String, success: Bool, detail: String) {
        let key = "\(bundleId)|\(appVersion)|\(iosVersion)|\(dylib)"
        records[key] = [
            "bundle_id": bundleId,
            "app_version": appVersion,
            "ios_version": iosVersion,
            "dylib": dylib,
            "success": success,
            "detail": detail,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        save()
    }

    func query(bundleId: String? = nil, appVersion: String? = nil, iosVersion: String? = nil) -> [[String: Any]] {
        var results: [[String: Any]] = []
        for (_, record) in records {
            if let bid = bundleId, (record["bundle_id"] as? String) != bid { continue }
            if let ver = appVersion, (record["app_version"] as? String) != ver { continue }
            if let ios = iosVersion, (record["ios_version"] as? String) != ios { continue }
            results.append(record)
        }
        return results
    }

    func compatibility(bundleId: String, appVersion: String, iosVersion: String, dylib: String) -> String {
        let key = "\(bundleId)|\(appVersion)|\(iosVersion)|\(dylib)"
        if let record = records[key], let success = record["success"] as? Bool {
            return success ? "✅ 已知可用" : "❌ 已知不兼容"
        }
        // 模糊匹配同 bundleId + dylib
        let similar = records.values.filter {
            ($0["bundle_id"] as? String) == bundleId && ($0["dylib"] as? String) == dylib
        }
        if !similar.isEmpty {
            let successCount = similar.filter { $0["success"] as? Bool == true }.count
            return "⚠️ 需要确认（同 App 历史成功率 \(successCount)/\(similar.count)）"
        }
        return "❓ 未测试"
    }
}

final class CompatibilityTool: MCPTool {
    let definition = ToolDefinition(
        name: "compat.check",
        summary: "查询/记录 App 版本 + iOS 版本 + dylib 的注入兼容矩阵。自动标记已知可用/不兼容/未测试。",
        parameters: [
            "action": "check（查询兼容性）、record（记录结果）、list（列出所有记录）",
            "bundle_id": "目标 App Bundle ID",
            "dylib": "dylib 名称",
            "success": "record 时是否成功",
            "detail": "record 时的详细信息"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String) ?? "check"
        let bundleId = params["bundle_id"] as? String ?? ""
        let dylib = params["dylib"] as? String ?? ""

        if action == "record" {
            let success = (params["success"] as? Bool) ?? false
            let detail = params["detail"] as? String ?? ""
            let appVersion = (try? NSDictionary(contentsOfFile: "/\(bundleId)".appending("/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "unknown"
            let iosVersion = UIDevice.current.systemVersion
            CompatibilityMatrix.shared.record(bundleId: bundleId, appVersion: appVersion, iosVersion: iosVersion, dylib: dylib, success: success, detail: detail)
            return ["recorded": true]
        }

        if action == "list" {
            return ["records": CompatibilityMatrix.shared.query(), "count": CompatibilityMatrix.shared.query().count]
        }

        // check
        let appVersion = params["app_version"] as? String ?? "unknown"
        let iosVersion = params["ios_version"] as? String ?? UIDevice.current.systemVersion
        let status = CompatibilityMatrix.shared.compatibility(bundleId: bundleId, appVersion: appVersion, iosVersion: iosVersion, dylib: dylib)
        let history = CompatibilityMatrix.shared.query(bundleId: bundleId)
        return [
            "bundle_id": bundleId,
            "dylib": dylib,
            "compatibility": status,
            "history": Array(history.prefix(10))
        ]
    }
}

// MARK: - 崩溃复现 hook 模板生成

final class CrashReproTool: MCPTool {
    let definition = ToolDefinition(
        name: "crash.repro_template",
        summary: "根据崩溃日志自动生成 Logos hook 模板，用于在下一次运行时捕获触发崩溃的参数和调用顺序。输出可直接编译的 Tweak.x 代码。",
        parameters: [
            "crash_log": "崩溃日志文本（必填，可用 diagnose.crash 获取）",
            "bundle_id": "目标 App Bundle ID（用于生成 filter）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let crashLog = params["crash_log"] as? String, !crashLog.isEmpty else {
            throw MCPError.invalidParams("crash_log required")
        }
        let bundleId = params["bundle_id"] as? String ?? "com.example.app"

        // 从崩溃日志中提取关键信息
        var exceptionType = ""
        var crashedThread = "0"
        var crashedMethod = ""
        var crashedClass = ""

        for line in crashLog.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Exception Type:") {
                exceptionType = trimmed.replacingOccurrences(of: "Exception Type: ", with: "")
            } else if trimmed.hasPrefix("Triggered by Thread:") {
                crashedThread = trimmed.replacingOccurrences(of: "Triggered by Thread: ", with: "")
            } else if trimmed.contains("Thread \(crashedThread) Crashed:") {
                // 下一帧是崩溃位置
            }
        }

        // 提取崩溃线程第一帧
        let lines = crashLog.components(separatedBy: .newlines)
        var inCrashedThread = false
        var firstFrame = ""
        for line in lines {
            if line.contains("Thread \(crashedThread) Crashed:") {
                inCrashedThread = true
                continue
            }
            if inCrashedThread && !line.isEmpty {
                firstFrame = line.trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // 生成 hook 模板
        let template = """
        // 自动生成的崩溃复现 hook 模板
        // 崩溃类型: \(exceptionType)
        // 崩溃线程: \(crashedThread)
        // 崩溃帧: \(firstFrame)
        // 目标: \(bundleId)

        #import <Foundation/Foundation.h>
        #import <UIKit/UIKit.h>

        static NSString *kCrashLog = @"/var/mobile/Documents/Workspace/crash_repro_\(bundleId).log";

        static void logRepro(NSString *msg) {
            NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
            NSString *line = [NSString stringWithFormat:@"[%@] %@\\n", ts, msg];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kCrashLog];
            if (!fh) { [[NSData data] writeToFile:kCrashLog atomically:YES]; fh = [NSFileHandle fileHandleForWritingAtPath:kCrashLog]; }
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }

        // TODO: 根据崩溃帧替换下面的 hook 目标
        // 用 binary.symbols 搜索崩溃帧中的类名和方法名
        %hook UIApplication

        - (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
            logRepro(@"[REPRO] application didFinishLaunching");
            logRepro([NSString stringWithFormat:@"[REPRO] launchOptions: %@", launchOptions]);
            return %orig;
        }

        %end

        // 崩溃帧 hook（需根据实际崩溃位置修改）
        // %hook <CrashedClass>
        // - (<ReturnType>)<crashedMethod>:(id)arg {
        //     logRepro([NSString stringWithFormat:@"[REPRO] %@ called with: %@", NSStringFromSelector(_cmd), arg]);
        //     @try {
        //         return %orig(arg);
        //     } @catch (NSException *e) {
        //         logRepro([NSString stringWithFormat:@"[REPRO] CAUGHT: %@", e]);
        //         logRepro([NSString stringWithFormat:@"[REPRO] callStack: %@", [e callStackSymbols]]);
        //         @throw e;
        //     }
        // }
        // %end

        __attribute__((constructor))
        static void init() {
            logRepro(@"[REPRO] CrashRepro dylib loaded");
        }
        """

        // 输出到工作区
        let outputPath = NSHomeDirectory().appending("/Documents/Workspace/crash_repro_\(bundleId).x")
        try? template.write(toFile: outputPath, atomically: true, encoding: .utf8)

        return [
            "exception_type": exceptionType,
            "crashed_thread": crashedThread,
            "crashed_frame": firstFrame,
            "template_path": outputPath,
            "template": template,
            "next_steps": [
                "1. 用 binary.symbols 搜索崩溃帧中的类名和方法名",
                "2. 替换模板中的 TODO 部分，hook 崩溃方法",
                "3. 线上编译生成 dylib",
                "4. 注入目标 App，复现崩溃",
                "5. 读取 crash_repro_*.log 查看调用参数"
            ]
        ]
    }
}
