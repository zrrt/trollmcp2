import Foundation

import UIKit
import Security
import AdSupport



// v2.9.72：符号浏览器 + 插件系统 + 兼容矩阵 + 崩溃复现 hook 模板生成



// MARK: - 二进制符号浏览器



final class BinarySymbolsTool: MCPTool {

    let definition = ToolDefinition(

        name: "binary.symbols",

        summary: "Extract symbols from a binary file (ObjC classes/methods, strings, imports). Use for: reverse engineer an app, analyze binary structure, find interesting classes/methods to hook. Don't use for: inject dylib (use injection.enable), check app deps (use app.deps). Example: user says 'what classes does 小红书 have' → extract ObjC symbols.",

        parameters: [

            "path": "Path to binary file (get main binary path via ipa.inspect)",

            "type": "What to extract: objc (classes/methods) / strings / imports / all (default)",

            "search": "Search keyword filter (optional)",

            "limit": "Max results (default 100)"

        ],

    verified: true, category: "analysis")



    func invoke(_ params: [String: Any]) throws -> [String: Any] {

        guard let path = params["path"] as? String, !path.isEmpty else {

            throw MCPError.invalidParams("path required")

        }

        let type = (params["type"] as? String) ?? "all"

        let search = (params["search"] as? String) ?? ""

        let limit = (params["limit"] as? Int) ?? 100



        guard FileManager.default.fileExists(atPath: path) else {

            return ["error": "file not found: \(path)"]

        }



        var result: [String: Any] = ["path": path, "type": type]



        // 用 nm 提取符号 (如果有 nm）

        let nmPath = Bundle.main.path(forResource: "nm", ofType: nil, inDirectory: "bin") ?? "/usr/bin/nm"

        if FileManager.default.fileExists(atPath: nmPath) {

            let nmResult = InjectionManager.shared.spawnRootDetailed(nmPath, args: ["-g", "-U", path], timeout: 60)

            var symbols: [String] = []

            for line in nmResult.stdout.components(separatedBy: .newlines) {

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

                let strResult = InjectionManager.shared.spawnRootDetailed(stringsPath, args: [path], timeout: 60)

                var strings: [String] = []

                for line in strResult.stdout.components(separatedBy: .newlines) {

                    let trimmed = line.trimmingCharacters(in: .whitespaces)

                    if trimmed.count >= 4 && (search.isEmpty || trimmed.localizedCaseInsensitiveContains(search)) {

                        strings.append(trimmed)

                    }

                }

                result["strings"] = Array(strings.prefix(limit))

                result["strings_total"] = strings.count

            }

        }



        // Objective-C class name (从字符串中提取）

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

            result["hint"] = "nm/strings not bundled; use otool -ov to view ObjC sections, or ldid -e to view signature"

        }



        return result

    }

}



// MARK: - 插件系统 (简化版）



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

        summary: "List installed dylib plugins (built-in + user). Use for: see what plugins are available, check plugin status. Don't use for: inject plugin into app (use injection.enable), list injected apps (use injection.status). Example: user says 'what plugins are available' → list plugins.",

        parameters: [

            "action": "list (show all) / enable / disable",

            "name": "Plugin name (required for enable/disable action)"

        ],

    verified: true, category: "analysis")



    func invoke(_ params: [String: Any]) throws -> [String: Any] {

        let action = (params["action"] as? String) ?? "list"

        if action == "list" {

            return ["plugins": PluginManager.shared.list(), "count": PluginManager.shared.plugins.count]

        }

        return ["error": "unsupported action: \(action)"]

    }

}



// MARK: - 崩溃复现 hook 模板生成



final class CrashReproTool: MCPTool {

    let definition = ToolDefinition(

        name: "crash.repro_template",

        summary: "Generate a Logos hook template from a crash report. Use for: debug why app crashes, create hook to reproduce/fix crash. Don't use for: collect crash logs (use log.collect), analyze crash (use diagnose.crash). Example: user says '小红书 keeps crashing, generate a hook for me' → generate repro template.",

        parameters: [

            "crash_log": "Crash log text (get from diagnose.crash first)",

            "bundle_id": "Target App bundle ID (for context)"

        ],

    verified: true, category: "diagnose")



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

        // 用 binary.symbols 搜索崩溃帧中的class name和方法名

        %hook UIApplication



        - (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

            logRepro(@"[REPRO] application didFinishLaunching");

            logRepro([NSString stringWithFormat:@"[REPRO] launchOptions: %@", launchOptions]);

            return %orig;

        }



        %end



        // 崩溃帧 hook (需根据实际崩溃位置修改）

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

                "1. use binary.symbols to find the class name and method name in the crash frame",

                "2. replace the TODO parts in the template to hook the crashing method",

                "3. compile the dylib online",

                "4. inject into the target App and reproduce the crash",

                "5. read crash_repro_*.log to inspect the call arguments"

            ]

        ]

    }

}

// MARK: - v2.9.90 高级工具组 (借鉴 Fuck 巨魔工具箱：opainject 内存injected / ProbeEngine 类探测 / FuckEngine 配置化 Hook / 绿盾式设备伪装）

// MARK: - 进程/启动辅助

enum ProcessHelper {
    // MARK: - libproc 进程枚举 (v3.0.42：根治 pidOf——不依赖 /bin/ps 输出解析）
    // iOS 系统库 /usr/lib/libproc.dylib：proc_listpids 枚举全部 pid，proc_pidpath 拿可执行路径。
    // 比 ps 解析稳 (Darwin ps 的 comm= 列有 15 字符截断/格式差异问题），且无需额外权限。
    private enum LibProc {
        typealias ListPidsFn = @convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?, Int32) -> Int32
        typealias PidPathFn = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
        static let handle: UnsafeMutableRawPointer? = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY)
        static let listPids: ListPidsFn? = {
            guard let h = handle, let s = dlsym(h, "proc_listpids") else { return nil }
            return unsafeBitCast(s, to: ListPidsFn.self)
        }()
        static let pidPath: PidPathFn? = {
            guard let h = handle, let s = dlsym(h, "proc_pidpath") else { return nil }
            return unsafeBitCast(s, to: PidPathFn.self)
        }()
    }

    /// 按可执行名查 pid：优先 libproc (枚举所有 pid + 完整可执行路径），failed回退 ps 解析。
    static func pidOf(executableName: String) -> Int? {
        // 方案 A：libproc (平台原生）
        if let pid = pidOfViaLibProc(executableName: executableName) {
            return pid
        }
        // 方案 B：ps -A 解析 (兜底）
        let (_, out) = InjectionManager.shared.spawn("/bin/ps", args: ["ps", "-A", "-o", "pid=,comm="])
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let pidStr = String(trimmed[..<spaceIdx]).trimmingCharacters(in: .whitespaces)
            let comm = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            // 精确匹配
            if comm == executableName, let pid = Int(pidStr) {
                return pid
            }
            // 包含匹配 (comm 可能是完整路径）
            if comm.contains(executableName), let pid = Int(pidStr) {
                // 确保是完整文件名匹配，不是子串
                let lastPath = (comm as NSString).lastPathComponent
                if lastPath == executableName {
                    return pid
                }
            }
        }
        return nil
    }

    private static func pidOfViaLibProc(executableName: String) -> Int? {
        guard let listPids = LibProc.listPids, let pidPath = LibProc.pidPath else { return nil }
        let capacity = 4096
        var pids = [Int32](repeating: 0, count: capacity)
        let bytes = listPids(1 /* PROC_ALL_PIDS */, 0, &pids, Int32(capacity * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<Int32>.size
        for i in 0..<min(count, capacity) {
            if pids[i] <= 0 { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            let len = pidPath(pids[i], &buf, UInt32(buf.count))
            if len > 0 {
                let path = String(cString: buf)
                if (path as NSString).lastPathComponent == executableName {
                    return Int(pids[i])
                }
            }
        }
        return nil
    }

    /// 启动 App：优先 SBSLaunchApplicationWithIdentifier (需 frontboard/springboard entitlements），failed回退 openURL，再failed返回提示
    @discardableResult
    static func launchApp(bundleId: String) -> (Bool, String) {
        if let handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY) {
            typealias SBSLaunchFn = @convention(c) (CFString, Bool) -> Int32
            if let sym = dlsym(handle, "SBSLaunchApplicationWithIdentifier") {
                let fn = unsafeBitCast(sym, to: SBSLaunchFn.self)
                let ret = fn(bundleId as CFString, false)
                if ret == 0 {
                    return (true, "SBSLaunchApplicationWithIdentifier launch OK")
                }
            }
            dlclose(handle)
        }
        if let url = URL(string: "trollmcp2://") {
            if UIThreadBridge.openURL(url, timeout: 3) { return (true, "openURL launch OK") }
        }
        return (false, "cannot auto-launch (SBS unavailable and App has no URL scheme), open the target App manually on the home screen")
    }

    /// 找 App 主可执行名 (CFBundleExecutable）
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

// MARK: - injection.mem：内存injected (opainject）

final class InjectionMemTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.mem",
        summary: "Memory injection: inject dylib into a running app WITHOUT modifying its files. Use for: temporary testing, probing app internals. Don't use for: permanent injection (use injection.enable, survives restart). Note: dies when app restarts. Example: user says 'temporarily inject 小红书 for testing' → memory inject.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "dylib_path": "Dylib path (optional, default: ProbeAgent)",
            "auto_launch": "Auto-launch app if not running (default: true)"
        ],
        returns: [
            "status": "injected_alive_http / injected_alive_nohttp / injected_crashed / failed",
            "pid": "Target App process id",
            "app_alive": "true if App still running after injection",
            "http_ready": "true if localhost:4791 HTTP server is up",
            "note": "Human-readable result explanation"
        ],
        verified: true
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)", "hint": "use injection.list to search"]
        }

        // v3.0.89：iOS 17+ 不支持内存injected (opainject 依赖 ct_bypass，已失效）
        let majorVer = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if majorVer >= 17 {
            return [
                "error": "iOS 17+ does not support memory injection (opainject/ct_bypass deprecated)",
                "hint": "use injection.static (static injection: insert_dylib + trollstorehelper reinstall)",
                "ios_version": majorVer
            ]
        }

        let exeName = ProcessHelper.executableName(for: app)
        var dylibPath = params["dylib_path"] as? String ?? ""
        if dylibPath.isEmpty {
            dylibPath = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
        }
        guard !dylibPath.isEmpty, FileManager.default.fileExists(atPath: dylibPath) else {
            return ["error": "dylib does not exist: \(dylibPath)", "hint": "pass dylib_path or ensure built-in tweaks/ProbeAgent.dylib exists"]
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
            return ["error": "target App not running, cannot memory-inject", "hint": "open target App first, or pass auto_launch=true"]
        }

        AuditLog.shared.log("injection.mem", detail: "\(bundleId) pid=\(targetPid)")
        let (exit, output) = InjectionManager.shared.injectDylib(pid: targetPid, dylib: dylibPath)
        let success = output.contains("dlopen succeeded") || (exit == 0 && output.contains("handle"))
        // v3.0.59：注入后确认进程存活 (一键闭环：启动→注入→存活确认）
        let alive = ProcessHelper.pidOf(executableName: exeName) != nil
        // v3.0.65：注入后 HTTP ready检查 (ProbeAgent/ControlAgent localhost:4791）
        var httpReady = false
        if success && alive {
            for _ in 0..<10 {
                usleep(500_000)  // 0.5s × 10 = 5s
                if let url = URL(string: "http://127.0.0.1:4791/"),
                   let resp = try? Data(contentsOf: url, options: .alwaysMapped),
                   !resp.isEmpty {
                    httpReady = true
                    break
                }
            }
        }
        return [
            "status": success ? (alive ? (httpReady ? "injected_alive_http" : "injected_alive_nohttp") : "injected_crashed") : "failed",
            "mode": "memory",
            "bundle_id": bundleId,
            "app": app.name,
            "pid": targetPid,
            "app_alive": alive,
            "http_ready": httpReady,
            "dylib": dylibPath,
            "exit": exit,
            "output": output,
            "note": success
                ? (alive ? (httpReady ? "Memory injection OK: process alive + HTTP ready. Ready for probe.inspect." : "Memory injection OK: process alive but HTTP not ready (dylib loaded, service not up. Check dylib deps/port conflict).") : "Memory injection OK but App crashed (dylib caused crash. Try different dylib or rollback).")
                : "opainject failed. See output for reason (permission/arch/process state)."
        ]
    }
}

// MARK: - probe.inspect：运行时类探测 (ProbeAgent）

final class ProbeInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "probe.inspect",
        summary: "Inspect running app internals: list ObjC classes, see class methods/properties, read UserDefaults. Use for: reverse engineer an app, understand how it works internally, find classes to hook. Don't use for: static binary analysis (use binary.symbols), AI-powered analysis (use ai.analyze_app). Prerequisite: inject ProbeAgent first. Example: user says 'what ViewController classes does 小红书 have' → probe classes.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "query": "What to inspect: classes (list all) / class (details of one) / userdefaults / info",
            "class_name": "Specific class name (when query=class)",
            "prefix": "Filter classes by name prefix (reduces noise)",
            "limit": "Max classes to return (default 30, max 100)",
            "cleanup": "Remove ProbeAgent after query (default false)"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)", "hint": "use injection.list to search"]
        }

        // v3.0.89：iOS 17+ 不支持探针injected (opainject 依赖 ct_bypass，已失效）
        let majorVer = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if majorVer >= 17 {
            return [
                "error": "iOS 17+ does not support probe.inspect (depends on opainject/ct_bypass, deprecated)",
                "hint": "use injection.static (static injection) then retry",
                "ios_version": majorVer
            ]
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
                    let (_, out) = InjectionManager.shared.injectDylib(pid: pid, dylib: dylib)
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        } else {
            let (launched, msg) = ProcessHelper.launchApp(bundleId: bundleId)
            if !launched { return ["error": msg, "hint": "open target App manually then retry"] }
            var pid: Int? = nil
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
            if let pid = pid {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.injectDylib(pid: pid, dylib: dylib)
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        }
        guard probeInjected else {
            let running = ProcessHelper.pidOf(executableName: exeName) != nil
            return ["error": "ProbeAgent injection failed (\(running ? "opainject rejected/anti-debug blocked" : "App not running"))",
                    "next_step": running ? "target has anti-injection/anti-debug detection; try injection.mem memory-injection bypass" : "start target App with app.start bundle_id first, or open manually then retry",
                    "hint": "injection failure does not mean the App is broken; follow next_step first"]
        }

        var ready = false
        for _ in 0..<10 {
            usleep(400_000)
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 { ready = true; break }
        }
        guard ready else {
            return ["error": "ProbeAgent HTTP not ready (port 4791)"]
        }

        var path = "/probe/classes"
        var limit = params["limit"] as? Int ?? 30
        if limit > 100 { limit = 100 }
        let prefix = params["prefix"] as? String ?? ""
        switch query {
        case "class":
            guard let cn = params["class_name"] as? String, !cn.isEmpty else {
                throw MCPError.invalidParams("query=class requires class_name param")
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
            return ["error": "ProbeAgent query timeout"]
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
                result["cleanup"] = "target process killed; memory injection disappears with the process"
            }
        } else {
            result["cleanup"] = "injection kept (queryable while process alive); clear with cleanup=true or App restart"
        }
        AuditLog.shared.log("probe.inspect", detail: "\(bundleId) query=\(query)")
        return result
    }
}

// MARK: - hook.apply：配置化 Hook (ConfigHook）

final class HookApplyTool: MCPTool {
    let definition = ToolDefinition(
        name: "hook.apply",
        summary: "Apply UI customization hook (change navbar color, show startup alert, log methods). Use for: customize app UI, add startup popup, log specific method calls. Don't use for: memory modification (use memory), device spoofing (use device.fake). Example: user says 'change 小红书 navbar to red' → apply hook config.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "config": "JSON config: navbar color, tint color, startup alert, method log rules",
            "restart": "Restart app after applying (default true)"
        ], verified: true, category: "injection")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        var config: [String: Any] = [:]
        if let cfg = params["config"] as? String, !cfg.isEmpty {
            guard let data = cfg.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPError.invalidParams("config is not valid JSON")
            }
            config = obj
        } else if let dict = params["config"] as? [String: Any] {
            config = dict
        }
        guard !config.isEmpty else {
            throw MCPError.invalidParams("config cannot be empty")
        }
        guard ProcessHelper.writeWorkspaceConfig("hook_config.json", dict: config) else {
            return ["error": "failed to write hook_config.json (workspace permission)"]
        }
        let injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
        if !injected {
            let dylib = ProcessHelper.tweakPath("ConfigHook.dylib") ?? ""
            guard !dylib.isEmpty else { return ["error": "built-in ConfigHook.dylib does not exist"] }
            let r = try InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
            if (r["status"] as? String) != "injected" {
                return ["error": "ConfigHook injection failed", "detail": r]
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
            "note": relaunchNote + "; restart App after changing config (no re-injection needed)"
        ]
    }
}

// MARK: - device.fake / device.restore：设备伪装 (FakeDevice，绿盾式）

final class DeviceFakeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.fake",
        summary: "Spoof device info (model, iOS version, etc.). Use for: fake device model to bypass device detection, test app on different device. Don't use for: restore real device info (use device.restore), inject dylib (use injection.enable). Prerequisite: inject FakeDevice.dylib first. Example: user says 'spoof phone as iPhone 16 Pro Max' → fake device.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "name": "Fake device name (e.g. iPhone 16 Pro Max)",
            "model": "Fake model (e.g. iPhone)",
            "model_identifier": "Fake model identifier (e.g. iPhone17,2; some Apps read via sysctl, info only)",
            "system_version": "Fake iOS version (e.g. 18.0)",
            "mode": "memory (default, opainject memory injection) / file (legacy file injection, high risk, special use only)"
        ],
        verified: true, category: "device")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        var config: [String: Any] = [:]
        if let name = params["name"] as? String, !name.isEmpty { config["name"] = name }
        if let model = params["model"] as? String, !model.isEmpty { config["model"] = model }
        if let mi = params["model_identifier"] as? String, !mi.isEmpty { config["modelIdentifier"] = mi }
        if let sv = params["system_version"] as? String, !sv.isEmpty { config["systemVersion"] = sv }
        guard !config.isEmpty else {
            throw MCPError.invalidParams("provide at least one spoof field (name/model/model_identifier/system_version)")
        }
        guard ProcessHelper.writeWorkspaceConfig("fake_device.json", dict: config) else {
            return ["error": "failed to write fake_device.json (workspace permission)"]
        }

        let mode = (params["mode"] as? String) ?? "memory"
        if mode == "file" {
            // 旧式文件注入：保留但明确标注风险
            let dylib = ProcessHelper.tweakPath("FakeDevice.dylib") ?? ""
            guard !dylib.isEmpty else { return ["error": "built-in FakeDevice.dylib does not exist"] }
            let r = try InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
            if (r["status"] as? String) != "injected" {
                return ["error": "FakeDevice file injection failed", "detail": r]
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
                "note": "file injection applied (App binary modified, backed up). Use device.restore to revert"
            ]
        }

        // 默认：内存injected (opainject）——不碰任何文件
        let exeName = ProcessHelper.executableName(for: app)
        let dylib = ProcessHelper.tweakPath("FakeDevice.dylib") ?? ""
        guard !dylib.isEmpty, FileManager.default.fileExists(atPath: dylib) else {
            return ["error": "built-in FakeDevice.dylib does not exist", "hint": "check tweaks/FakeDevice.dylib inside the IPA"]
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
            return ["error": "target App failed to launch, cannot memory-inject", "hint": "open target App manually then retry"]
        }
        let (exit, output) = InjectionManager.shared.injectDylib(pid: targetPid, dylib: dylib)
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
                ? "内存注入OK：FakeDevice 已在进程内生效，未改动任何文件；App 重启后自动还原真实设备"
                : "opainject failed (见 output)。App 文件未被动过，无需恢复"
        ]
    }
}

final class DeviceRestoreTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.restore",
        summary: "Restore real device info. Use for: undo device spoofing after testing. Don't use for: start spoofing (use device.fake), check device info (use device.info). Example: user says 'restore real device info' → restore device.",
        parameters: ["bundle_id": "Target app bundle ID"], verified: true, category: "device")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let removed = ProcessHelper.removeWorkspaceConfig("fake_device.json")
        guard let app = AppCatalog.find(bundleId) else {
            return ["status": "restored", "bundle_id": bundleId, "config_removed": removed,
                    "injection_removed": false, "note": "App not found; fake_device.json deleted"]
        }
        let exe = ProcessHelper.executableName(for: app)
        // 检查是否为文件injected (旧版遗留）
        let injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
        var injectionRemoved = false
        var restoreError = ""
        if injected {
            do {
                let r = try InjectionManager.shared.disable(bundleId: bundleId)
                injectionRemoved = ((r["status"] as? String) == "reverted") || !((r["restored_from_backup"] as? [String]) ?? []).isEmpty
                if !injectionRemoved {
                    restoreError = "disable 未确认还原 (见 injection.disable 输出)"
                }
            } catch {
                restoreError = "恢复failed：\(error.localizedDescription)"
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
                    "note": "fake_device.json deleted and App restarted; old file injection uninstall failed, use Emergency Restore (one-click full recovery) in the Inject and Automation page"]
        }
        return [
            "status": "restored",
            "bundle_id": bundleId,
            "config_removed": removed,
            "injection_removed": injectionRemoved,
            "mode": injected ? "file" : "memory",
            "note": injected
                ? "已删除 fake_device.json、卸载旧文件注入并重启 App"
                : "已删除 fake_device.json 并重启 App (内存注入随进程结束自动消失，零残留)"
        ]
    }
}

// MARK: - v2.9.95 设备指纹 / 容器 / entitlements 工具 (对齐 Fuck 工具箱 + 绿盾式）

/// 查看 App entitlements (ldid -e 解析）
final class AppEntitlementsTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.entitlements",
        summary: "Check an app's code signing entitlements (cs_debug, task_for_pid, etc). Use for: check if app can be debugged, see if it has special permissions. Don't use for: check if encrypted (use app.encrypt_info), list dependencies (use app.deps). Example: user says 'can 小红书 be debugged' → check entitlements.",
        parameters: ["bundle_id": "Target App bundle ID (e.g. com.xingin.discover)"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        let main = InjectionManager.shared.executablePath(app)
        // v2.9.116：先查加密——加密二进制 ldid 解不出 entitlements，不能当"没有"
        var cryptID: UInt32 = 0
        if let mo = MachOAnalyzer.analyze(main) { cryptID = mo.cryptID }
        let (c, o) = InjectionManager.shared.runAsRoot("ldid", args: ["-e", main])
        if c != 0 {
            var out: [String: Any] = ["error": "ldid -e failed (\(c))", "output": String(o.prefix(500)), "bundle_id": bundleId]
            out["parse_error"] = cryptID > 0 ? "target App is encrypted (cryptid=\(cryptID))，entitlements 被加密掩盖，非“没有权限”" : "Mach-O 解析failed (可能混淆/特殊头)，非“没有权限”"
            out["next_step"] = cryptID > 0 ? "先executed app.decrypt 砸壳后重试" : "用 fs.hexdump 查看主二进制头部确认格式"
            return out
        }
        var dict: [String: Any] = [:]
        var parseError = ""
        // v3.0.42：用原始字节解析 (系统 App entitlements 是二进制 plist，UTF-8 转 String 会损坏）
        let (rc, raw) = InjectionManager.shared.runAsRootData("ldid", args: ["-e", main])
        if rc == 0,
           let d = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any] {
            dict = d
        } else {
            parseError = cryptID > 0 ? "加密 App (cryptid=\(cryptID))entitlements 无法解析，先砸壳" : "ldid 输出非 plist，解析failed"
        }
        var out: [String: Any] = [
            "bundle_id": bundleId,
            "entitlements": dict,
            "keychain_groups": dict["keychain-access-groups"] ?? [],
            "platform_app": dict["platform-application"] as? Bool ?? false,
            "no_sandbox": dict["com.apple.private.security.no-sandbox"] as? Bool ?? false,
            "task_for_pid": dict["task_for_pid-allow"] as? Bool ?? false,
            "get_task_allow": dict["get-task-allow"] as? Bool ?? false,
            "parse_error": parseError,
            "hint": parseError.isEmpty ? "keychain_groups can be passed to device.keychain_wipe to precisely clear the target App keychain" : parseError + " (empty value does not mean no permission)"
        ]
        return out
    }
}

/// 清理指定 App 钥匙串条目 (按 entitlements 的 keychain-access-groups 精确删除）
final class KeychainWipeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.keychain_wipe",
        summary: "Wipe an app's keychain (login tokens/passwords). Use for: reset app login state, force re-login. Don't use for: clear app cache (use cleanup.execute), uninstall app (use app.uninstall). Warning: this will log the user out! Example: user says 'log out of 小红书' → wipe keychain.",
        parameters: ["bundle_id": "Target App bundle_id (required). e.g. com.xingin.discover"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        let main = InjectionManager.shared.executablePath(app)
        let (c, o) = InjectionManager.shared.runAsRoot("ldid", args: ["-e", main])
        var groups: [String] = []
        if c == 0, let data = o.data(using: .utf8),
           let d = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let gs = d["keychain-access-groups"] as? [String] {
            groups = gs
        }
        // v3.0.42：ldid 可能输出二进制 plist——用原始字节重试
        if groups.isEmpty {
            let (rc2, raw2) = InjectionManager.shared.runAsRootData("ldid", args: ["-e", main])
            if rc2 == 0,
               let d2 = try? PropertyListSerialization.propertyList(from: raw2, options: [], format: nil) as? [String: Any],
               let gs2 = d2["keychain-access-groups"] as? [String] {
                groups = gs2
            }
        }
        if groups.isEmpty { groups = ["TROLLTROLL.com.trollagent.app"] }
        var deleted = 0
        var failed = 0
        var errors: [String] = []
        // v2.9.96：优先 root 直改 keychain-2.db (sqlite_wipe 内置工具），
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
                "hint": "deleted target App entries from system keychain database by keychain-access-groups (login state will reset). If App is still running, kill and restart it"
            ]
        }
        errors.append("sqlite_wipe: \(rc) \(rout)")
        // fallback：SecItemDelete (受本 App entitlements 限制，尽量删自己组）
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
                ? "部分条目需要系统级 keychain 权限 (本 App 未声明该组)。"
                : "已清理目标 App 钥匙串条目 (登录态将被重置)"
        ]
    }
}

// v2.9.312：device.keychain_reset 已删除——清空整机钥匙串太危险，
// 会导致所有 App 密码/登录态丢失。保留 device.keychain_wipe (按指定 App 清理）。

/// 广告标识符 (IDFA）读取 / 刷新
final class AdvertisingTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.advertising",
        summary: "Read or reset IDFA (advertising identifier). Use for: check ad tracking status, reset ad ID for fresh identity. Don't use for: device spoofing (use device.fake), wipe app keychain (use device.keychain_wipe). Example: user says 'reset advertising ID' → reset IDFA.",
        parameters: ["action": "read (show current) / reset (get new ID)"],
        verified: true, category: "device")
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
                result["reset"] = "resetIdentifier called"
                result["idfa_after"] = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            } else {
                result["reset"] = "resetIdentifier not supported on this system (public API removed on iOS14+)"
                result["hint"] = "IDFA refresh restricted on iOS14+"
            }
        }
        return result
    }
}

/// 读取设备/App 的 identifierForVendor
final class IdfvTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.idfv",
        summary: "Read IDFV (identifier for vendor) - device fingerprint. Use for: check device fingerprint, see if app can track you. Don't use for: reset IDFV (no public API, delete app instead), spoof device model (use device.fake). Example: user says 'what is my IDFV' → read IDFV.",
        parameters: ["bundle_id": "Optional: target app bundle ID"],
        verified: true, category: "device")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let sys = UIDevice.current.identifierForVendor?.uuidString ?? "N/A"
        var extra: [String: Any] = ["system_idfv": sys]
        if let bid = params["bundle_id"] as? String, !bid.isEmpty {
            extra["requested_bundle_id"] = bid
            extra["app_idfv"] = "(read inside target App process; device-level IDFV above)"
        }
        extra["hint"] = "IDFV has no public refresh API: system decides after App deletion; usually unchanged on backup restore"
        return extra
    }
}

/// 刷新 (重置）指定 App 数据容器——数据保留在备份目录，可 restore 恢复
final class RefreshContainerTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.refresh_container",
        summary: "Reset app data container (rename old one to backup, system creates fresh empty one). Use for: factory reset app data but can restore later. Don't use for: wipe keychain only (use device.keychain_wipe), uninstall app (use app.uninstall). Warning: this clears all app data! Example: user says 'reset 小红书 to factory state' → refresh container.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "restore": "If true, restore from previous backup instead of resetting"
        ], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        guard let container = app.containerPath, !container.isEmpty else {
            return ["error": "cannot locate data container", "hint": "LSApplicationProxy returned no dataContainerURL (may lack AppDataContainers entitlement)"]
        }
        let restore = (params["restore"] as? Bool) ?? false
        let bk = container + ".trollagent.bak"
        let im = InjectionManager.shared
        if restore {
            if !FileManager.default.fileExists(atPath: bk) {
                return ["error": "no backup directory found", "backup": bk]
            }
            _ = im.runAsRoot("rm", args: ["-rf", container])
            let (c, o) = im.runAsRoot("mv", args: [bk, container])
            if c != 0 { return ["error": "restore failed (\(c)): \(o)"] }
            _ = im.runAsRoot("chown", args: ["33:33", container])
            let exe = ProcessHelper.executableName(for: app)
            _ = im.runAsRoot("killall", args: ["killall", "-9", exe])
            return ["status": "restored", "container": container, "hint": "container restored from backup and process killed, App data back to pre-reset state"]
        }
        if FileManager.default.fileExists(atPath: bk) {
            _ = im.runAsRoot("rm", args: ["-rf", bk])
        }
        let (c, o) = im.runAsRoot("mv", args: [container, bk])
        if c != 0 { return ["error": "reset failed (\(c)): \(o)"] }
        _ = im.runAsRoot("chown", args: ["33:33", bk])
        let exe = ProcessHelper.executableName(for: app)
        _ = im.runAsRoot("killall", args: ["killall", "-9", exe])
        return [
            "status": "refreshed",
            "container": container,
            "backup": bk,
            "hint": "container renamed as backup (data kept). System rebuilds an empty container on next App launch. To restore: call again with restore=true"
        ]
    }
}

// MARK: - HTTP 辅助 (localhost）

private func httpGet(port: Int, path: String, timeout: TimeInterval = 4) -> (Int, String)? {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    setTimeoutInterval(timeout, on: &request)
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

// MARK: - v2.9.99 一键新机 (绿盾式组合）

/// automation.new_device — 一键新机：整机 keychain 重置 + 广告符刷新 + 设备伪装组合
/// 组合复用 KeychainResetTool / AdvertisingTool / DeviceFakeTool，一步done"新机"环境。
final class NewDeviceTool: MCPTool {
    let definition = ToolDefinition(
        name: "automation.new_device",
        summary: "One-click 'new device' mode: spoof device model + refresh advertising ID. Use for: make app think it's a brand new phone, reset device fingerprint. Don't use for: just change device name (use device.fake), wipe app data (use device.refresh_container). Example: user says 'pretend I got a new phone' → new device mode.",
        parameters: [
            "bundle_id": "Target App bundle_id (optional)",
            "name": "Fake device name (default: iPhone 16 Pro Max)",
            "model": "Fake model (default: iPhone)",
            "model_identifier": "Fake model ID (default: iPhone17,2)",
            "system_version": "Fake iOS version (default: 18.0)",
            "refresh_idfa": "Refresh advertising ID (default: true)"
        ],
    verified: true)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        var steps: [[String: Any]] = []
        var warnings: [String] = []

        // v2.9.312：整机 keychain 清空已永久移除 (误清用户登录态事故）
        steps.append(["step": "keychain_reset", "result": "REMOVED: whole-device keychain wipe disabled"])

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
                "hint": "inject FakeDevice.dylib into target App afterwards to take effect"
            ]])
        }

        var result: [String: Any] = ["status": "done", "steps": steps]
        if !warnings.isEmpty { result["warnings"] = warnings }
        result["idfv_note"] = "IDFV is system-generated and not directly modifiable; for a fully new one use device.refresh_container (rebuilds container and wipes target App data, use with care)"
        result["hint"] = "restart the phone for full keychain rebuild; spoofing takes effect after FakeDevice.dylib injected and target App restarted"
        return result
    }
}

// MARK: - v2.9.100 AI 分析引擎 (Fuck 工具箱同款思路：采集 → LLM → 生成 hook 方案 → 应用）

/// ai.analyze_app — 采集目标 App ObjC 类结构，用当前配置的模型 LLM 分析出 hook 方案，
/// 自动写入 hook_config.json 并injected ConfigHook 生效 (methodLog 方法调用日志 + 可选 UI 配色）。
final class AiAnalyzeTool: MCPTool {
    let definition = ToolDefinition(
        name: "ai.analyze_app",
        summary: "AI-powered app analysis (reverse engineering). Use for: understand how an app works internally, find VIP check logic, find ad SDK classes. Don't use for: simple file reading (use fs.read), memory modification (use memory). Prerequisite: inject ProbeAgent first. Example: user says 'analyze how 小红书 checks VIP' → analyze app with vip direction.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "direction": "What to analyze: vip / remove_ads / bypass_detection / full / custom",
            "custom_hint": "Specific analysis target (when direction=custom)",
            "max_classes": "Max classes to collect (default 80, max 150)",
            "prefix": "Only collect classes starting with this prefix (reduces noise)"
        ],
    verified: true, category: "automation", prerequisites: ["App 已injected ProbeAgent (先 inject enable ProbeAgent)", "加密 App 需run app.decrypt 砸壳 (ai.analyze_app 依赖静态分析)"])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)", "hint": "use injection.list to search"]
        }
        guard let cfg = ModelStore.shared.defaultConfig else {
            return ["error": "no model configured", "hint": "add and select a model in Settings -> Model API first"]
        }
        let direction = (params["direction"] as? String) ?? "全面"
        let customHint = params["custom_hint"] as? String ?? ""
        let maxClasses = min((params["max_classes"] as? Int) ?? 80, 150)
        let prefix = (params["prefix"] as? String) ?? ""
        let exeName = ProcessHelper.executableName(for: app)

        // v2.9.116：前置自检 1——加密 App 直接提示砸壳，不浪费 opainject
        let mainBin = app.path + "/" + exeName
        if let mo = MachOAnalyzer.analyze(mainBin), mo.cryptID > 0 {
            return ["error": "target App is encrypted (cryptid=\(mo.cryptID)), ProbeAgent cannot inject to read class structure",
                    "next_step": "run app.decrypt first, then retry ai.analyze_app",
                    "hint": "all App Store apps are encrypted, must decrypt first"]
        }

        // 1) 确保 ProbeAgent 在目标进程里 (复用 probe 注入逻辑）
        var probeInjected = false
        if let pid = ProcessHelper.pidOf(executableName: exeName) {
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 {
                probeInjected = true
            } else {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.injectDylib(pid: pid, dylib: dylib)
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        } else {
            let (launched, msg) = ProcessHelper.launchApp(bundleId: bundleId)
            if !launched { return ["error": msg, "hint": "open target App manually then retry"] }
            var pid: Int? = nil
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
            if let pid = pid {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.injectDylib(pid: pid, dylib: dylib)
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        }
        guard probeInjected else {
            let running = ProcessHelper.pidOf(executableName: exeName) != nil
            return ["error": "ProbeAgent injection failed (\(running ? "opainject rejected/anti-debug blocked" : "App not running"))",
                    "next_step": running ? "target has anti-injection/anti-debug detection; try injection.mem memory-injection bypass" : "start target App with app.start bundle_id first, or open manually then retry",
                    "hint": "injection failure does not mean the App is broken; follow next_step first"]
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
            return ["error": "class list is empty", "hint": "confirm App is running and ProbeAgent injected (probe.inspect bundle_id first)"]
        }

        // 3) 构造 LLM 提示词
        let classSummary = classes.prefix(maxClasses).map {
            "\($0["name"] as? String ?? "?")(\($0["instanceMethodCount"] as? Int ?? 0))"
        }.joined(separator: ", ")
        let directionDesc = direction == "自定义" && !customHint.isEmpty ? customHint : direction
        let prompt = """
        你是资深 iOS 逆向工程师。目标 App 的 ObjC 运行时类列表 (名称+实例方法数)：
        \(classSummary)
        分析方向：\(directionDesc)
        请从中挑选最值得 hook 的 3~8 个类，输出严格 JSON (不要 markdown 代码块)：
        {"methodLog":[{"class":"class name","selector":"method name (with colon)","note":"why hook it"}],"reason":"one-line overall approach"}
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
            return ["error": "AI analysis failed", "detail": errText.isEmpty ? "no response" : errText,
                    "hint": "check model config; if the relay has poor /chat/completions support, switch protocol in Model API"]
        }

        // 4) 解析 JSON (剥掉可能的 ```json 围栏 / 前后杂文）
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
            return ["error": "AI returned no valid methodLog", "ai_output": String(resultText.prefix(300))]
        }

        // 5) 应用 (写入 hook_config.json + injected ConfigHook + 重启）
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
            "hint": "methodLog logs print to the target App console; re-send with hook.apply after changing config. To restore original use injection.disable"
        ]
    }
}
