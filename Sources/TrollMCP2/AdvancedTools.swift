import Foundation

import UIKit
import Security
import AdSupport



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

            let appVersion = (NSDictionary(contentsOfFile: "/\(bundleId)".appending("/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "unknown"

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

// MARK: - v2.9.90 高级工具组（借鉴 Fuck 巨魔工具箱：opainject 内存注入 / ProbeEngine 类探测 / FuckEngine 配置化 Hook / 绿盾式设备伪装）

// MARK: - 进程/启动辅助

enum ProcessHelper {
    /// 按可执行名查 pid（ps -A 解析；App 主进程名 = CFBundleExecutable）
    static func pidOf(executableName: String) -> Int? {
        let (_, out) = InjectionManager.shared.spawn("/bin/ps", args: ["ps", "-A", "-o", "pid=,comm="])
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let pidStr = String(trimmed[..<spaceIdx]).trimmingCharacters(in: .whitespaces)
            let comm = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            if comm == executableName, let pid = Int(pidStr) {
                return pid
            }
        }
        return nil
    }

    /// 启动 App：优先 SBSLaunchApplicationWithIdentifier（需 frontboard/springboard entitlements），失败回退 openURL，再失败返回提示
    @discardableResult
    static func launchApp(bundleId: String) -> (Bool, String) {
        if let handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY) {
            typealias SBSLaunchFn = @convention(c) (CFString, Bool) -> Int32
            if let sym = dlsym(handle, "SBSLaunchApplicationWithIdentifier") {
                let fn = unsafeBitCast(sym, to: SBSLaunchFn.self)
                let ret = fn(bundleId as CFString, false)
                if ret == 0 {
                    return (true, "SBSLaunchApplicationWithIdentifier 启动成功")
                }
            }
            dlclose(handle)
        }
        if let url = URL(string: "trollmcp2://") {
            var opened = false
            let sem = DispatchSemaphore(value: 0)
            UIApplication.shared.open(url, options: [:]) { success in
                opened = success
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 3)
            if opened { return (true, "openURL 启动成功") }
        }
        return (false, "无法自动启动（SBS 不可用且 App 无 URL scheme），请在桌面手动打开目标 App")
    }

    /// 找 App 主可执行名（CFBundleExecutable）
    static func executableName(for app: AppCatalog.AppEntry) -> String {
        guard let dict = NSDictionary(contentsOfFile: app.path + "/Info.plist"),
              let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty else {
            return app.bundleId.components(separatedBy: ".").last ?? app.bundleId
        }
        return exe
    }

    /// tweaks 目录内 dylib 路径
    static func tweakPath(_ name: String) -> String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("tweaks").appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 写 JSON 配置文件到工作区
    static func writeWorkspaceConfig(_ fileName: String, dict: [String: Any]) -> Bool {
        let dir = "/var/mobile/Documents/Workspace"
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let path = dir + "/" + fileName
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    static func removeWorkspaceConfig(_ fileName: String) -> Bool {
        let path = "/var/mobile/Documents/Workspace/" + fileName
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - injection.mem：内存注入（opainject）

final class InjectionMemTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.mem",
        summary: "内存注入：用 opainject 向运行中的目标 App 进程注入 dylib（task_for_pid + ROP → dlopen）。不改二进制、无备份、零残留，App 重启后注入自动消失。适合临时测试/探测。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "dylib_path": "要注入的 dylib 绝对路径（可选，不填则用内置 tweaks/ProbeAgent.dylib）",
            "auto_launch": "App 未运行时是否尝试自动启动（true/false，默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)", "hint": "用 injection.list 搜索"]
        }
        let exeName = ProcessHelper.executableName(for: app)
        var dylibPath = params["dylib_path"] as? String ?? ""
        if dylibPath.isEmpty {
            dylibPath = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
        }
        guard !dylibPath.isEmpty, FileManager.default.fileExists(atPath: dylibPath) else {
            return ["error": "dylib 不存在: \(dylibPath)", "hint": "传 dylib_path 或确保内置 tweaks/ProbeAgent.dylib 存在"]
        }

        var pid = ProcessHelper.pidOf(executableName: exeName)
        if pid == nil {
            let autoLaunch = (params["auto_launch"] as? Bool) ?? true
            if autoLaunch {
                _ = ProcessHelper.launchApp(bundleId: bundleId)
                for _ in 0..<10 {
                    usleep(500_000)
                    pid = ProcessHelper.pidOf(executableName: exeName)
                    if pid != nil { break }
                }
            }
        }
        guard let targetPid = pid else {
            return ["error": "目标 App 未运行，无法内存注入", "hint": "先打开目标 App，或传 auto_launch=true"]
        }

        AuditLog.shared.log("injection.mem", detail: "\(bundleId) pid=\(targetPid)")
        let (exit, output) = InjectionManager.shared.runAsRoot("opainject", args: ["\(targetPid)", dylibPath])
        let success = output.contains("dlopen succeeded") || (exit == 0 && output.contains("handle"))
        return [
            "status": success ? "injected" : "failed",
            "mode": "memory",
            "bundle_id": bundleId,
            "app": app.name,
            "pid": targetPid,
            "dylib": dylibPath,
            "exit": exit,
            "output": output,
            "note": success ? "内存注入成功：进程内已 dlopen，不改文件；App 重启后注入自动消失" : "opainject 失败，见 output 定位原因（权限/架构/进程状态）"
        ]
    }
}

// MARK: - probe.inspect：运行时类探测（ProbeAgent）

final class ProbeInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "probe.inspect",
        summary: "运行时探测目标 App：枚举 ObjC 类/类详情（方法·属性·ivars）/UserDefaults/进程信息。用 ProbeAgent 内存注入 + localhost:4791 查询，探测完可自动清理。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "query": "查询类型：classes（类列表）/ class（类详情）/ userdefaults / info，默认 classes",
            "class_name": "query=class 时要查的类名（如 UIApplicationDelegate 实现类）",
            "prefix": "类名前缀过滤（可选，如 QQ 前缀避免全量）",
            "limit": "类列表条数上限（默认 30，最大 100）",
            "cleanup": "探测完是否移除注入（true/false，默认 false——进程活着期间可反复查询）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)", "hint": "用 injection.list 搜索"]
        }
        let query = (params["query"] as? String) ?? "classes"
        let exeName = ProcessHelper.executableName(for: app)

        var probeInjected = false
        if let pid = ProcessHelper.pidOf(executableName: exeName) {
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 {
                probeInjected = true
            } else {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.runAsRoot("opainject", args: ["\(pid)", dylib])
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        } else {
            let (launched, msg) = ProcessHelper.launchApp(bundleId: bundleId)
            if !launched { return ["error": msg, "hint": "手动打开目标 App 后重试"] }
            var pid: Int? = nil
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
            if let pid = pid {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.runAsRoot("opainject", args: ["\(pid)", dylib])
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        }
        guard probeInjected else {
            return ["error": "ProbeAgent 注入失败（App 未运行或 opainject 失败）", "hint": "确认 App 在前台运行，或先手动打开"]
        }

        var ready = false
        for _ in 0..<10 {
            usleep(400_000)
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 { ready = true; break }
        }
        guard ready else {
            return ["error": "ProbeAgent HTTP 未就绪（端口 4791）"]
        }

        var path = "/probe/classes"
        var limit = params["limit"] as? Int ?? 30
        if limit > 100 { limit = 100 }
        let prefix = params["prefix"] as? String ?? ""
        switch query {
        case "class":
            guard let cn = params["class_name"] as? String, !cn.isEmpty else {
                throw MCPError.invalidParams("query=class 需要 class_name 参数")
            }
            path = "/probe/class?name=" + cn.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        case "userdefaults":
            path = "/probe/userdefaults"
        case "info":
            path = "/status"
        default:
            var qs = "limit=\(limit)"
            if !prefix.isEmpty { qs += "&prefix=" + prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }
            path = "/probe/classes?" + qs
        }
        guard let (code, body) = httpGet(port: 4791, path: path) else {
            return ["error": "ProbeAgent 查询超时"]
        }
        var result: [String: Any] = ["status": code == 200 ? "ok" : "error", "query": query, "bundle_id": bundleId, "app": app.name]
        if let data = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result["data"] = obj
        } else {
            result["raw"] = body
        }

        let cleanup = (params["cleanup"] as? Bool) ?? false
        if cleanup {
            if let pid = ProcessHelper.pidOf(executableName: exeName) {
                _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exeName])
                result["cleanup"] = "已 kill 目标进程，内存注入随进程退出消失"
            }
        } else {
            result["cleanup"] = "保留注入（进程存活期间可反复查询）；用 cleanup=true 或重启 App 清除"
        }
        AuditLog.shared.log("probe.inspect", detail: "\(bundleId) query=\(query)")
        return result
    }
}

// MARK: - hook.apply：配置化 Hook（ConfigHook）

final class HookApplyTool: MCPTool {
    let definition = ToolDefinition(
        name: "hook.apply",
        summary: "配置化 Hook：向目标 App 注入 ConfigHook，并写入 hook_config.json（导航栏颜色/全局 tint/启动弹窗/方法调用日志）。改配置后重启 App 即生效，无需重新注入。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "config": "配置 JSON 字符串：{\"navBarColor\":\"#1A73E8\",\"navBarTitleColor\":\"#FFFFFF\",\"windowTint\":\"#FF0000\",\"alert\":{\"title\":\"..\",\"message\":\"..\"},\"methodLog\":[{\"class\":\"X\",\"selector\":\"y\"}]}",
            "restart": "注入后是否重启 App（true/false，默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)"]
        }
        var config: [String: Any] = [:]
        if let cfg = params["config"] as? String, !cfg.isEmpty {
            guard let data = cfg.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPError.invalidParams("config 不是合法 JSON")
            }
            config = obj
        } else if let dict = params["config"] as? [String: Any] {
            config = dict
        }
        guard !config.isEmpty else {
            throw MCPError.invalidParams("config 不能为空")
        }
        guard ProcessHelper.writeWorkspaceConfig("hook_config.json", dict: config) else {
            return ["error": "写入 hook_config.json 失败（工作区权限）"]
        }
        let injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
        if !injected {
            let dylib = ProcessHelper.tweakPath("ConfigHook.dylib") ?? ""
            guard !dylib.isEmpty else { return ["error": "内置 ConfigHook.dylib 不存在"] }
            let r = try InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
            if (r["status"] as? String) != "injected" {
                return ["error": "ConfigHook 注入失败", "detail": r]
            }
        }
        let restart = (params["restart"] as? Bool) ?? true
        var relaunchNote = ""
        if restart {
            let exe = ProcessHelper.executableName(for: app)
            _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
            _ = ProcessHelper.launchApp(bundleId: bundleId)
            relaunchNote = "已重启 App 使配置生效"
        } else {
            relaunchNote = "未重启；下次 App 启动时配置生效"
        }
        AuditLog.shared.log("hook.apply", detail: "\(bundleId) keys=\(config.keys)")
        return [
            "status": "applied",
            "bundle_id": bundleId,
            "app": app.name,
            "config_path": "/var/mobile/Documents/Workspace/hook_config.json",
            "config": config,
            "injected": true,
            "note": relaunchNote + "；修改配置后重启 App 即生效（无需重新注入）"
        ]
    }
}

// MARK: - device.fake / device.restore：设备伪装（FakeDevice，绿盾式）

final class DeviceFakeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.fake",
        summary: "设备伪装（内存注入版，v2.9.93）：写 fake_device.json 后向目标 App 进程内存注入 FakeDevice.dylib（opainject，不改二进制、零残留、重启还原）。默认 memory 模式绝不修改 App 文件，杜绝注入损坏。",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "name": "伪装机型名称（如 iPhone 16 Pro Max）",
            "model": "伪装机型（如 iPhone）",
            "model_identifier": "伪装机型标识（如 iPhone17,2；部分 App 通过 sysctl 读取，仅作信息字段）",
            "system_version": "伪装系统版本（如 18.0）",
            "mode": "memory（默认，opainject 内存注入）/ file（旧式文件注入，风险高，仅特殊场景用）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)"]
        }
        var config: [String: Any] = [:]
        if let name = params["name"] as? String, !name.isEmpty { config["name"] = name }
        if let model = params["model"] as? String, !model.isEmpty { config["model"] = model }
        if let mi = params["model_identifier"] as? String, !mi.isEmpty { config["modelIdentifier"] = mi }
        if let sv = params["system_version"] as? String, !sv.isEmpty { config["systemVersion"] = sv }
        guard !config.isEmpty else {
            throw MCPError.invalidParams("至少提供一个伪装字段（name/model/model_identifier/system_version）")
        }
        guard ProcessHelper.writeWorkspaceConfig("fake_device.json", dict: config) else {
            return ["error": "写入 fake_device.json 失败（工作区权限）"]
        }

        let mode = (params["mode"] as? String) ?? "memory"
        if mode == "file" {
            // 旧式文件注入：保留但明确标注风险
            let dylib = ProcessHelper.tweakPath("FakeDevice.dylib") ?? ""
            guard !dylib.isEmpty else { return ["error": "内置 FakeDevice.dylib 不存在"] }
            let r = try InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
            if (r["status"] as? String) != "injected" {
                return ["error": "FakeDevice 文件注入失败", "detail": r]
            }
            let exe = ProcessHelper.executableName(for: app)
            _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
            _ = ProcessHelper.launchApp(bundleId: bundleId)
            AuditLog.shared.log("device.fake.file", detail: "\(bundleId) \(config)")
            return [
                "status": "faked",
                "mode": "file",
                "bundle_id": bundleId,
                "app": app.name,
                "config": config,
                "config_path": "/var/mobile/Documents/Workspace/fake_device.json",
                "note": "文件注入已应用（改动 App 二进制，有备份）。恢复请用 device.restore"
            ]
        }

        // 默认：内存注入（opainject）——不碰任何文件
        let exeName = ProcessHelper.executableName(for: app)
        let dylib = ProcessHelper.tweakPath("FakeDevice.dylib") ?? ""
        guard !dylib.isEmpty, FileManager.default.fileExists(atPath: dylib) else {
            return ["error": "内置 FakeDevice.dylib 不存在", "hint": "检查 IPA 内 tweaks/FakeDevice.dylib"]
        }
        var pid = ProcessHelper.pidOf(executableName: exeName)
        if pid == nil {
            _ = ProcessHelper.launchApp(bundleId: bundleId)
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
        }
        guard let targetPid = pid else {
            return ["error": "目标 App 未能启动，无法内存注入", "hint": "手动打开目标 App 后重试"]
        }
        let (exit, output) = InjectionManager.shared.runAsRoot("opainject", args: ["\(targetPid)", dylib])
        let ok = output.contains("dlopen succeeded") || (exit == 0 && output.contains("handle"))
        AuditLog.shared.log("device.fake.mem", detail: "\(bundleId) pid=\(targetPid) ok=\(ok)")
        return [
            "status": ok ? "faked" : "failed",
            "mode": "memory",
            "bundle_id": bundleId,
            "app": app.name,
            "pid": targetPid,
            "config": config,
            "config_path": "/var/mobile/Documents/Workspace/fake_device.json",
            "exit": exit,
            "output": output,
            "note": ok
                ? "内存注入成功：FakeDevice 已在进程内生效，未改动任何文件；App 重启后自动还原真实设备"
                : "opainject 失败（见 output）。App 文件未被动过，无需恢复"
        ]
    }
}

final class DeviceRestoreTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.restore",
        summary: "还原设备伪装：删除 fake_device.json 并还原目标 App 真实设备信息。内存注入版：杀掉 App 进程即完全还原（零残留）；若之前是文件注入则完整卸载注入。",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let removed = ProcessHelper.removeWorkspaceConfig("fake_device.json")
        guard let app = AppCatalog.find(bundleId) else {
            return ["status": "restored", "bundle_id": bundleId, "config_removed": removed,
                    "injection_removed": false, "note": "App 未找到；已删除 fake_device.json"]
        }
        let exe = ProcessHelper.executableName(for: app)
        // 检查是否为文件注入（旧版遗留）
        let injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
        var injectionRemoved = false
        var restoreError = ""
        if injected {
            do {
                let r = try InjectionManager.shared.disable(bundleId: bundleId)
                injectionRemoved = ((r["status"] as? String) == "reverted") || !((r["restored_from_backup"] as? [String]) ?? []).isEmpty
                if !injectionRemoved {
                    restoreError = "disable 未确认还原（见 injection.disable 输出）"
                }
            } catch {
                restoreError = "恢复失败：\(error.localizedDescription)"
                AuditLog.shared.log("device.restore.error", detail: "\(bundleId) \(restoreError)")
            }
        }
        // 内存注入：杀进程即还原；文件注入：杀进程确保新状态生效
        _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
        _ = ProcessHelper.launchApp(bundleId: bundleId)
        AuditLog.shared.log("device.restore", detail: "\(bundleId) injected=\(injected)")
        if !restoreError.isEmpty {
            return ["status": "error", "bundle_id": bundleId, "config_removed": removed,
                    "injection_removed": injectionRemoved, "error": restoreError,
                    "note": "fake_device.json 已删除并重启 App；但旧文件注入卸载失败，请用「注入与自动化」页的紧急恢复一键全恢复"]
        }
        return [
            "status": "restored",
            "bundle_id": bundleId,
            "config_removed": removed,
            "injection_removed": injectionRemoved,
            "mode": injected ? "file" : "memory",
            "note": injected
                ? "已删除 fake_device.json、卸载旧文件注入并重启 App"
                : "已删除 fake_device.json 并重启 App（内存注入随进程结束自动消失，零残留）"
        ]
    }
}

// MARK: - v2.9.95 设备指纹 / 容器 / entitlements 工具（对齐 Fuck 工具箱 + 绿盾式）

/// 查看 App entitlements（ldid -e 解析）
final class AppEntitlementsTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.entitlements",
        summary: "查看指定 App 的权限声明（entitlements，ldid -e 解析）：keychain 组、沙箱、task_for_pid、平台应用等",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)"]
        }
        let main = InjectionManager.shared.executablePath(app)
        let (c, o) = InjectionManager.shared.runAsRoot("ldid", args: ["-e", main])
        if c != 0 { return ["error": "ldid -e 失败(\(c))", "output": o] }
        var dict: [String: Any] = [:]
        if let data = o.data(using: .utf8),
           let d = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            dict = d
        }
        return [
            "bundle_id": bundleId,
            "entitlements": dict,
            "keychain_groups": dict["keychain-access-groups"] ?? [],
            "platform_app": dict["platform-application"] as? Bool ?? false,
            "no_sandbox": dict["com.apple.private.security.no-sandbox"] as? Bool ?? false,
            "task_for_pid": dict["task_for_pid-allow"] as? Bool ?? false,
            "get_task_allow": dict["get-task-allow"] as? Bool ?? false,
            "hint": "keychain_groups 可直接传给 device.keychain_wipe 精确清理目标 App 钥匙串"
        ]
    }
}

/// 清理指定 App 钥匙串条目（按 entitlements 的 keychain-access-groups 精确删除）
final class KeychainWipeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.keychain_wipe",
        summary: "清理指定 App 的钥匙串条目：按目标 App 的 keychain-access-groups 用 SecItemDelete 精确删除（密码/令牌/密钥）。跨组删除受系统权限限制时给出提示",
        parameters: ["bundle_id": "目标 App Bundle ID（必填）"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)"]
        }
        let main = InjectionManager.shared.executablePath(app)
        let (c, o) = InjectionManager.shared.runAsRoot("ldid", args: ["-e", main])
        var groups: [String] = []
        if c == 0, let data = o.data(using: .utf8),
           let d = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let gs = d["keychain-access-groups"] as? [String] {
            groups = gs
        }
        if groups.isEmpty { groups = ["TROLLTROLL.dev.trollmcp2.app"] }
        var deleted = 0
        var failed = 0
        var errors: [String] = []
        // v2.9.96：优先 root 直改 keychain-2.db（sqlite_wipe 内置工具），
        // 不受跨组 entitlements 限制，精确删除目标 App 全部钥匙串条目。
        let im = InjectionManager.shared
        let (rc, rout) = im.runAsRoot("sqlite_wipe", args: ["sqlite_wipe"] + groups)
        if rc == 0 {
            let tokens = rout.split(separator: " ")
            let wiped = (tokens.count >= 3 ? Int(tokens[1]) : nil) ?? 0
            return [
                "bundle_id": bundleId,
                "method": "sqlite_wipe(root keychain-2.db)",
                "groups_tried": groups,
                "deleted_count": wiped,
                "output": rout.trimmingCharacters(in: .whitespacesAndNewlines),
                "hint": "已按 keychain-access-groups 从系统 keychain 数据库删除目标 App 条目（登录态将被重置）。如 App 仍在运行，建议杀进程后重启"
            ]
        }
        errors.append("sqlite_wipe: \(rc) \(rout)")
        // fallback：SecItemDelete（受本 App entitlements 限制，尽量删自己组）
        for g in groups {
            for cls in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey] {
                let q: [String: Any] = [
                    kSecClass as String: cls,
                    kSecAttrAccessGroup as String: g,
                    kSecMatchLimit as String: kSecMatchLimitAll
                ]
                let st = SecItemDelete(q as CFDictionary)
                if st == errSecSuccess { deleted += 1 }
                else if st != errSecItemNotFound {
                    failed += 1
                    errors.append("\(g): \(st)")
                }
            }
        }
        return [
            "bundle_id": bundleId,
            "groups_tried": groups,
            "deleted_count": deleted,
            "failed_count": failed,
            "errors": errors,
            "hint": failed > 0
                ? "部分条目需要系统级 keychain 权限（本 App 未声明该组）。彻底清空请用 device.keychain_reset（⚠️ 所有 App 登录态都会失效）"
                : "已清理目标 App 钥匙串条目（登录态将被重置）"
        ]
    }
}

/// 一键新机式：清空整机钥匙串（绿盾式核心）
final class KeychainResetTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.keychain_reset",
        summary: "清空整机钥匙串：删除 keychain-2.db 并重启 securityd（绿盾式一键新机核心）。⚠️ 所有 App 的密码/令牌/密钥全部失效，慎用",
        parameters: [:]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let db = "/var/Keychains/keychain-2.db"
        let (c1, o1) = InjectionManager.shared.runAsRoot("rm", args: ["-f", db, db + "-wal", db + "-shm"])
        if c1 != 0 { return ["error": "删除 keychain 数据库失败(\(c1)): \(o1)"] }
        let (c2, _) = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", "securityd"])
        return [
            "status": "reset",
            "removed": db,
            "securityd_restarted": c2 == 0,
            "hint": "securityd 已由 launchd 自动拉起并重建空 keychain。建议重启手机彻底生效。所有 App 登录态已清空"
        ]
    }
}

/// 广告标识符（IDFA）读取 / 刷新
final class AdvertisingTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.advertising",
        summary: "读取广告标识符 IDFA 与追踪限制状态；action=reset 尝试刷新广告符（私有 API，iOS14+ 受系统限制时如实返回）",
        parameters: ["action": "read（默认）/ reset"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String)?.lowercased() ?? "read"
        var result: [String: Any] = [:]
        let m = ASIdentifierManager.shared()
        result["idfa"] = m.advertisingIdentifier.uuidString
        result["tracking_enabled"] = m.isAdvertisingTrackingEnabled
        result["tracking_limited"] = !m.isAdvertisingTrackingEnabled
        if action == "reset" {
            let any = m as AnyObject
            let sel = NSSelectorFromString("resetIdentifier")
            if any.responds(to: sel) {
                any.perform(sel)
                result["reset"] = "已调用 resetIdentifier"
                result["idfa_after"] = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            } else {
                result["reset"] = "当前系统不支持 resetIdentifier（iOS14+ 已移除公开 API）"
                result["hint"] = "广告符刷新在 iOS14+ 受限；如需彻底换新，可配合 device.keychain_reset（清空含广告符的 keychain）"
            }
        }
        return result
    }
}

/// 读取设备/App 的 identifierForVendor
final class IdfvTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.idfv",
        summary: "读取设备级 IDFV 与目标 App 的 identifierForVendor，可用于设备指纹核对/复制",
        parameters: ["bundle_id": "可选：目标 App Bundle ID"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let sys = UIDevice.current.identifierForVendor?.uuidString ?? "N/A"
        var extra: [String: Any] = ["system_idfv": sys]
        if let bid = params["bundle_id"] as? String, !bid.isEmpty {
            extra["requested_bundle_id"] = bid
            extra["app_idfv"] = "(需在目标 App 进程内读取；设备级 IDFV 见上)"
        }
        extra["hint"] = "IDFV 无公开刷新 API：删除 App 后由系统决定是否变更，备份恢复场景一般不变"
        return extra
    }
}

/// 刷新（重置）指定 App 数据容器——数据保留在备份目录，可 restore 恢复
final class RefreshContainerTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.refresh_container",
        summary: "刷新指定 App 的数据容器：把现有容器改名备份（数据保留），杀进程后系统重建空容器（等于重置 App 数据但可恢复）。传 restore=true 把备份恢复回去",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "restore": "true 时把上次备份目录恢复回原容器"
        ]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)"]
        }
        guard let container = app.containerPath, !container.isEmpty else {
            return ["error": "无法定位数据容器", "hint": "LSApplicationProxy 未返回 dataContainerURL（可能缺 AppDataContainers 权限）"]
        }
        let restore = (params["restore"] as? Bool) ?? false
        let bk = container + ".trollagent.bak"
        let im = InjectionManager.shared
        if restore {
            if !FileManager.default.fileExists(atPath: bk) {
                return ["error": "没有找到备份目录", "backup": bk]
            }
            _ = im.runAsRoot("rm", args: ["-rf", container])
            let (c, o) = im.runAsRoot("mv", args: [bk, container])
            if c != 0 { return ["error": "恢复失败(\(c)): \(o)"] }
            _ = im.runAsRoot("chown", args: ["33:33", container])
            let exe = ProcessHelper.executableName(for: app)
            _ = im.runAsRoot("killall", args: ["killall", "-9", exe])
            return ["status": "restored", "container": container, "hint": "已从备份恢复容器并杀进程，App 数据回到刷新前状态"]
        }
        if FileManager.default.fileExists(atPath: bk) {
            _ = im.runAsRoot("rm", args: ["-rf", bk])
        }
        let (c, o) = im.runAsRoot("mv", args: [container, bk])
        if c != 0 { return ["error": "刷新失败(\(c)): \(o)"] }
        _ = im.runAsRoot("chown", args: ["33:33", bk])
        let exe = ProcessHelper.executableName(for: app)
        _ = im.runAsRoot("killall", args: ["killall", "-9", exe])
        return [
            "status": "refreshed",
            "container": container,
            "backup": bk,
            "hint": "容器已改名备份（数据保留）。下次启动 App 系统会重建空容器。恢复：再次调用并传 restore=true"
        ]
    }
}

// MARK: - HTTP 辅助（localhost）

private func httpGet(port: Int, path: String, timeout: TimeInterval = 4) -> (Int, String)? {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.timeoutInterval = timeout
    var result: (Int, String)? = nil
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let data = data, let http = response as? HTTPURLResponse {
            result = (http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return result
}

// MARK: - v2.9.99 一键新机（绿盾式组合）

/// automation.new_device — 一键新机：整机 keychain 重置 + 广告符刷新 + 设备伪装组合
/// 组合复用 KeychainResetTool / AdvertisingTool / DeviceFakeTool，一步完成"新机"环境。
final class NewDeviceTool: MCPTool {
    let definition = ToolDefinition(
        name: "automation.new_device",
        summary: "一键新机（绿盾式组合，v2.9.99）：整机 keychain 重置 + 广告符刷新 + 设备伪装写入。⚠️ 会清空所有 App 登录态，慎用。传 bundle_id 则同时向目标 App 内存注入 FakeDevice.dylib",
        parameters: [
            "bundle_id": "目标 App Bundle ID（可选；传入则写伪装配置后立即内存注入 FakeDevice.dylib）",
            "name": "伪装机型名称（默认 iPhone 16 Pro Max）",
            "model": "伪装机型（默认 iPhone）",
            "model_identifier": "机型标识（默认 iPhone17,2）",
            "system_version": "伪装系统版本（默认 18.0）",
            "reset_keychain": "是否清空整机 keychain（默认 true）",
            "refresh_idfa": "是否尝试刷新广告符（默认 true）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        var steps: [[String: Any]] = []
        var warnings: [String] = []

        let resetKC = (params["reset_keychain"] as? Bool) ?? true
        if resetKC {
            do {
                steps.append(["step": "keychain_reset", "result": try KeychainResetTool().invoke([:])])
            } catch let e {
                warnings.append("keychain_reset: \(e)")
            }
        }

        let refreshIDFA = (params["refresh_idfa"] as? Bool) ?? true
        if refreshIDFA {
            do {
                steps.append(["step": "advertising_reset", "result": try AdvertisingTool().invoke(["action": "reset"])])
            } catch let e {
                warnings.append("advertising_reset: \(e)")
            }
        }

        let name = (params["name"] as? String) ?? "iPhone 16 Pro Max"
        let model = (params["model"] as? String) ?? "iPhone"
        let mi = (params["model_identifier"] as? String) ?? "iPhone17,2"
        let sv = (params["system_version"] as? String) ?? "18.0"

        if let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty {
            do {
                let r = try DeviceFakeTool().invoke([
                    "bundle_id": bundleId,
                    "name": name, "model": model,
                    "model_identifier": mi, "system_version": sv,
                    "mode": "memory"
                ])
                steps.append(["step": "device_fake", "result": r])
            } catch let e {
                warnings.append("device_fake: \(e)")
            }
        } else {
            let cfg: [String: Any] = [
                "name": name, "model": model,
                "modelIdentifier": mi, "systemVersion": sv
            ]
            let ok = ProcessHelper.writeWorkspaceConfig("fake_device.json", dict: cfg)
            steps.append(["step": "fake_config_written", "result": [
                "written": ok,
                "path": "/var/mobile/Documents/Workspace/fake_device.json",
                "hint": "之后向目标 App 注入 FakeDevice.dylib 即生效"
            ]])
        }

        var result: [String: Any] = ["status": "done", "steps": steps]
        if !warnings.isEmpty { result["warnings"] = warnings }
        result["idfv_note"] = "IDFV 由系统生成不可直接修改；如需完全换新可用 device.refresh_container（重建容器会清掉目标 App 数据，慎用）"
        result["hint"] = "建议重启手机让 keychain 重建彻底生效；伪装效果需目标 App 注入 FakeDevice.dylib 并重启目标 App"
        return result
    }
}

// MARK: - v2.9.100 AI 分析引擎（Fuck 工具箱同款思路：采集 → LLM → 生成 hook 方案 → 应用）

/// ai.analyze_app — 采集目标 App ObjC 类结构，用当前配置的模型 LLM 分析出 hook 方案，
/// 自动写入 hook_config.json 并注入 ConfigHook 生效（methodLog 方法调用日志 + 可选 UI 配色）。
final class AiAnalyzeTool: MCPTool {
    let definition = ToolDefinition(
        name: "ai.analyze_app",
        summary: "AI 分析引擎（v2.9.100）：注入 ProbeAgent 采集目标 App 类结构 → 当前模型 LLM 分析生成 hook 方案（methodLog 方法日志 + UI 配色）→ 自动写 hook_config.json 并注入 ConfigHook 生效。适合 VIP / 去广告 / 绕过检测 / UI 定制方向",
        parameters: [
            "bundle_id": "目标 App Bundle ID（必填）",
            "direction": "分析方向：vip / 去广告 / 绕过检测 / 全面 / 自定义（默认 全面）",
            "custom_hint": "direction=自定义 时的具体描述（如：找出会员判断逻辑）",
            "max_classes": "采集类上限（默认 80，最大 150；防 token 爆炸）",
            "prefix": "类名前缀过滤（可选，如 QQ，可大幅减少采集量）"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "未找到 App: \(bundleId)", "hint": "用 injection.list 搜索"]
        }
        guard let cfg = ModelStore.shared.defaultConfig else {
            return ["error": "未配置模型", "hint": "先在 设置 → 模型 API 添加并选中模型"]
        }
        let direction = (params["direction"] as? String) ?? "全面"
        let customHint = params["custom_hint"] as? String ?? ""
        let maxClasses = min((params["max_classes"] as? Int) ?? 80, 150)
        let prefix = (params["prefix"] as? String) ?? ""
        let exeName = ProcessHelper.executableName(for: app)

        // 1) 确保 ProbeAgent 在目标进程里（复用 probe 注入逻辑）
        var probeInjected = false
        if let pid = ProcessHelper.pidOf(executableName: exeName) {
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 {
                probeInjected = true
            } else {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.runAsRoot("opainject", args: ["\(pid)", dylib])
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        } else {
            let (launched, msg) = ProcessHelper.launchApp(bundleId: bundleId)
            if !launched { return ["error": msg, "hint": "手动打开目标 App 后重试"] }
            var pid: Int? = nil
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
            if let pid = pid {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.runAsRoot("opainject", args: ["\(pid)", dylib])
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        }
        guard probeInjected else {
            return ["error": "ProbeAgent 注入失败（App 未运行或 opainject 失败）", "hint": "确认 App 在前台运行，或先手动打开"]
        }

        // 2) 采集类列表
        var clsPath = "/probe/classes?limit=\(maxClasses)"
        if !prefix.isEmpty {
            let enc = prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prefix
            clsPath += "&prefix=\(enc)"
        }
        var classes: [[String: Any]] = []
        if let (code, body) = httpGet(port: 4791, path: clsPath, timeout: 8), code == 200,
           let data = body.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            classes = Array(arr.prefix(maxClasses))
        }
        guard !classes.isEmpty else {
            return ["error": "采集类列表为空", "hint": "确认 App 运行中且 ProbeAgent 已注入（可先 probe.inspect bundle_id）"]
        }

        // 3) 构造 LLM 提示词
        let classSummary = classes.prefix(maxClasses).map {
            "\($0["name"] as? String ?? "?")(\($0["instanceMethodCount"] as? Int ?? 0))"
        }.joined(separator: ", ")
        let directionDesc = direction == "自定义" && !customHint.isEmpty ? customHint : direction
        let prompt = """
        你是资深 iOS 逆向工程师。目标 App 的 ObjC 运行时类列表（名称+实例方法数）：
        \(classSummary)
        分析方向：\(directionDesc)
        请从中挑选最值得 hook 的 3~8 个类，输出严格 JSON（不要 markdown 代码块）：
        {"methodLog":[{"class":"类名","selector":"方法名(含冒号)","note":"为什么 hook 它"}],"reason":"一句总体思路"}
        如果方向涉及 UI 定制，可附加 "navBarColor":"#RRGGBB"、"windowTint":"#RRGGBB" 字段。
        """
        var resultText = ""
        var errText = ""
        let sem = DispatchSemaphore(value: 0)
        ModelAPIClient.shared.sendChat(config: cfg, messages: [["role": "user", "content": prompt]]) { res in
            switch res {
            case .success(let t): resultText = t
            case .failure(let e): errText = e.localizedDescription
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 95)
        if !errText.isEmpty || resultText.isEmpty {
            return ["error": "AI 分析失败", "detail": errText.isEmpty ? "无返回" : errText,
                    "hint": "检查模型配置；如中转站对 /chat/completions 支持不佳，可在模型 API 里切换协议"]
        }

        // 4) 解析 JSON（剥掉可能的 ```json 围栏 / 前后杂文）
        var config: [String: Any] = ["reason": String(resultText.prefix(200))]
        if let open = resultText.range(of: "{"),
           let close = resultText.range(of: "}", options: .backwards) {
            let sub = String(resultText[open.lowerBound...close.upperBound])
            if let data = sub.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                config = obj
            }
        }
        if (config["methodLog"] as? [[String: Any]] ?? []).isEmpty {
            return ["error": "AI 未返回有效 methodLog", "ai_output": String(resultText.prefix(300))]
        }

        // 5) 应用（写入 hook_config.json + 注入 ConfigHook + 重启）
        let applied = try HookApplyTool().invoke(["bundle_id": bundleId, "config": config, "restart": true])
        return [
            "status": "analyzed_and_applied",
            "bundle_id": bundleId,
            "app": app.name,
            "direction": direction,
            "analyzed_classes": classes.count,
            "ai_output": String(resultText.prefix(400)),
            "hook_config": config,
            "applied": applied,
            "hint": "methodLog 日志会打印到目标 App 控制台；改配置后用 hook.apply 重发即可。恢复原始用 injection.disable"
        ]
    }
}
