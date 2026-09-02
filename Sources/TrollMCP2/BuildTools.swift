import Foundation
import UIKit

// MARK: - v2.9.3 本机编译 / 构建能力
//
// 在 TrollMCP2 内原生实现"设备端编译桥"（此前是独立注入 dylib 的 TMBuildAgent 方案）。
// 工具链约定（用户手动放置到工作区，符合"编译依赖可手动下载/删除"）：
//   Documents/Workspace/toolchain/
//     bin/clang, bin/ld, bin/make, bin/perl, bin/ldid
//     theos/                 —— 完整 Theos（makefiles、lib、bin）
//     sdk/iPhoneOS*.sdk      —— iOS SDK 头文件
// 工程约定（与 project.generate_tweak 一致）：
//   Documents/Workspace/projects/<name>/  (Makefile + Tweak.x + <name>.plist)

/// 进程执行结果
struct BuildProcessResult {
    let exitCode: Int32      // 0=成功；-1=spawn/内部错误；-2=超时被杀
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let spawnError: String?
}

/// posix_spawn 执行器：支持工作目录、自定义环境变量、超时杀进程。
/// 相比 InjectionManager.spawn 扩展了 cwd/env/timeout，供编译这类长任务使用。
final class BuildRunner {
    static let shared = BuildRunner()

    private let maxOutputBytes = 4 * 1024 * 1024   // 输出截断上限 4MB

    /// 执行一条命令。
    /// iOS SDK 限制：posix_spawn 无法设置工作目录（无 posix_spawnattr_setworkingdir_np）、
    /// fork() 被标记 unavailable，因此需要工作目录时用 `/bin/sh -c "cd '<dir>' && exec ..."` 包装。
    /// - Parameters:
    ///   - executable: 可执行文件绝对路径
    ///   - args: 参数（不含可执行文件本身）
    ///   - workingDir: 工作目录（nil = 直接 spawn）
    ///   - env: 追加/覆盖的环境变量
    ///   - timeout: 超时秒数（0 = 不超时）
    func run(executable: String, args: [String], workingDir: String? = nil,
             env: [String: String] = [:], timeout: TimeInterval = 300) -> BuildProcessResult {
        guard FileManager.default.fileExists(atPath: executable) else {
            return BuildProcessResult(exitCode: -1, stdout: "", stderr: "executable not found: \(executable)", timedOut: false, spawnError: "not found")
        }

        if let wd = workingDir {
            var cmd = "cd \(shellQuote(wd)) && exec \(shellQuote(executable))"
            for a in args { cmd += " " + shellQuote(a) }
            return spawnPosix(path: "/bin/sh", args: ["-c", cmd], env: env, timeout: timeout)
        }
        return spawnPosix(path: executable, args: args, env: env, timeout: timeout)
    }

    /// posix_spawn + 输出落临时文件 + 超时杀进程
    private func spawnPosix(path: String, args: [String], env: [String: String], timeout: TimeInterval) -> BuildProcessResult {
        let argvList = [path] + args
        var argv: [UnsafeMutablePointer<CChar>?] = argvList.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        // 环境：继承当前 + 覆盖
        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { mergedEnv[k] = v }
        if mergedEnv["PATH"] == nil { mergedEnv["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        if mergedEnv["HOME"] == nil { mergedEnv["HOME"] = "/var/mobile" }
        var cenv: [UnsafeMutablePointer<CChar>?] = mergedEnv.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)
        defer { for p in cenv where p != nil { free(p) } }

        // 输出落临时文件（避免管道缓冲死锁，适合大输出）
        let outPath = NSTemporaryDirectory() + "tmcp_build_out_\(UUID().uuidString).log"
        let errPath = NSTemporaryDirectory() + "tmcp_build_err_\(UUID().uuidString).log"

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, outPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, errPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, path, &fileActions, nil, &argv, &cenv)
        posix_spawn_file_actions_destroy(&fileActions)

        if spawnStatus != 0 {
            let msg = "posix_spawn failed: \(String(cString: strerror(spawnStatus)))"
            try? FileManager.default.removeItem(atPath: outPath)
            try? FileManager.default.removeItem(atPath: errPath)
            return BuildProcessResult(exitCode: -1, stdout: "", stderr: msg, timedOut: false, spawnError: msg)
        }

        // 等待 + 超时杀进程
        var status: Int32 = 0
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid { break }
            if w == -1 && errno != EINTR { break }
            if Date() > deadline {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                timedOut = true
                break
            }
            usleep(200_000)
        }

        // 读回输出（截断）
        var outStr = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        var errStr = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
        if outStr.count > maxOutputBytes { outStr = String(outStr.prefix(maxOutputBytes)) }
        if errStr.count > maxOutputBytes { errStr = String(errStr.prefix(maxOutputBytes)) }
        try? FileManager.default.removeItem(atPath: outPath)
        try? FileManager.default.removeItem(atPath: errPath)

        let exitCode: Int32
        if timedOut {
            exitCode = -2
        } else {
            exitCode = Int32((UInt32(status) >> 8) & 0xff)   // WEXITSTATUS
        }
        return BuildProcessResult(exitCode: exitCode, stdout: outStr, stderr: errStr, timedOut: timedOut, spawnError: nil)
    }

    /// shell 单引号转义（用于安全拼接 `cd '<dir>'` 等）
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 通过 /bin/sh -c 执行一条命令（用于版本探测等）
    func shell(_ command: String, workingDir: String? = nil, env: [String: String] = [:], timeout: TimeInterval = 30) -> BuildProcessResult {
        run(executable: "/bin/sh", args: ["-c", command], workingDir: workingDir, env: env, timeout: timeout)
    }
}

// MARK: - 编译环境检查

/// build.environment：检查本机编译环境（toolchain/clang/make/theos/iOS SDK）
final class BuildEnvironmentTool: MCPTool {
    let definition = ToolDefinition(name: "build.environment",
        summary: "检查本机编译环境：toolchain 目录、clang/make/perl/ldid、Theos、iOS SDK",
        parameters: ["toolchain": "工具链路径：相对（toolchain = Workspace/toolchain）或绝对（/usr/local/theos 等系统路径）"])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let tcRel = params["toolchain"] as? String ?? "toolchain"
        let profile = resolveToolchainProfile(tcRel)
        let fm = FileManager.default

        var bins: [String: Any] = [:]
        // 系统布局：探测系统路径里的工具；规范布局：探测 toolchain/bin/
        for name in ["clang", "ld", "make", "perl", "ldid"] {
            let p: String
            switch name {
            case "clang": p = profile.clang
            case "make": p = profile.make ?? ""
            case "perl": p = profile.perl ?? ""
            case "ldid": p = profile.ldid ?? ""
            default: p = profile.isSystem ? "" : ((profile.binDir ?? "") as NSString).appendingPathComponent("ld")
            }
            let fileExists = !p.isEmpty && fm.fileExists(atPath: p)
            let executable = fileExists && fm.isExecutableFile(atPath: p)
            var info: [String: Any] = ["exists": fileExists, "executable": executable]
            if fileExists && executable {
                // 真实探测版本（短超时）
                let r = BuildRunner.shared.run(executable: p, args: ["--version"], timeout: 10)
                if r.exitCode == 0 {
                    let first = r.stdout.components(separatedBy: .newlines).first ?? ""
                    info["version"] = String(first.prefix(180))
                } else {
                    info["probe_error"] = String(r.stderr.prefix(180))
                }
            }
            bins[name] = info
        }

        // Theos
        var theosInfo: [String: Any] = [:]
        var isDir: ObjCBool = false
        let theosExists = fm.fileExists(atPath: profile.theos, isDirectory: &isDir) && isDir.boolValue
        theosInfo["exists"] = theosExists
        theosInfo["path"] = profile.theos
        if theosExists {
            theosInfo["makefiles"] = fm.fileExists(atPath: (profile.theos as NSString).appendingPathComponent("makefiles"), isDirectory: &isDir) && isDir.boolValue
            theosInfo["bin"] = fm.fileExists(atPath: (profile.theos as NSString).appendingPathComponent("bin"), isDirectory: &isDir) && isDir.boolValue
            theosInfo["has_ldid"] = fm.isExecutableFile(atPath: (profile.theos as NSString).appendingPathComponent("bin/ldid"))
            theosInfo["has_dpkg_deb"] = fm.isExecutableFile(atPath: (profile.theos as NSString).appendingPathComponent("bin/dpkg-deb"))
        }

        // iOS SDK
        var sdkList: [String] = []
        if profile.isSystem {
            let parents = [(profile.theos as NSString).appendingPathComponent("sdks"),
                           (profile.theos as NSString).appendingPathComponent("sdk")]
            for parent in parents {
                if let cands = try? fm.contentsOfDirectory(atPath: parent) {
                    sdkList.append(contentsOf: cands.filter { $0.hasSuffix(".sdk") }.sorted())
                }
            }
        } else if let binDir = profile.binDir {
            let sdkParent = ((binDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("sdk")
            if let cands = try? fm.contentsOfDirectory(atPath: sdkParent) {
                sdkList = cands.filter { $0.hasSuffix(".sdk") }.sorted()
            }
        }

        // 磁盘占用（系统布局不统计）
        let sizeBytes = profile.isSystem ? -1 : folderSize(profile.rootPath)

        let ready = (bins["clang"] as? [String: Any])?["exists"] as? Bool == true
            && (bins["make"] as? [String: Any])?["exists"] as? Bool == true
            && (bins["perl"] as? [String: Any])?["exists"] as? Bool == true
            && (theosInfo["exists"] as? Bool == true)
            && profile.sdkDir != nil

        AuditLog.shared.log("build.environment", detail: tcRel)
        return [
            "toolchain": tcRel,
            "layout": profile.isSystem ? "system(越狱/Nyxian)" : "canonical(bin/theos/sdk)",
            "theos_path": profile.theos,
            "sdk": profile.sdkDir ?? "",
            "bin": bins,
            "theos": theosInfo,
            "sdks": sdkList,
            "size_bytes": sizeBytes,
            "ready": ready,
            "hint": ready
                ? "环境就绪：可通过 build.run 编译 projects/ 下的 theos 或 clang 工程（toolchain 参数传 \(tcRel)）"
                : "缺少组件：toolchain=\(tcRel)。规范布局需 bin/clang+make+perl、theos/、sdk/iPhoneOS*.sdk；越狱机可用 toolchain=system 直接指向系统工具链（Nyxian）。获取方式参考 DeviceBuild/toolchain/README.md（a-Shell LLVM-on-iOS / Nyxian theos）"
        ]
    }

    private func folderSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let rel as String in en {
            let full = (path as NSString).appendingPathComponent(rel)
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

// MARK: - 参数类型容错（OpenAI 工具调用 schema 全 string，模型可能传 "true"/"300"）

/// 布尔参数：兼容 Bool / NSNumber / String("true"/"1"/"yes") / 缺省
func boolParam(_ params: [String: Any], _ key: String, _ def: Bool = false) -> Bool {
    if let b = params[key] as? Bool { return b }
    if let n = params[key] as? NSNumber { return n.boolValue }
    if let s = params[key] as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "true" || t == "1" || t == "yes" { return true }
        if t == "false" || t == "0" || t == "no" { return false }
    }
    return def
}

/// 数值参数：兼容 Double / NSNumber / String("300") / 缺省
func doubleParam(_ params: [String: Any], _ key: String, _ def: Double = 0) -> Double {
    if let d = params[key] as? Double { return d }
    if let n = params[key] as? NSNumber { return n.doubleValue }
    if let s = params[key] as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? def }
    return def
}

/// 字符串数组参数：兼容 [String] / 逗号分隔 String("a,b") / 缺省
func stringArrayParam(_ params: [String: Any], _ key: String) -> [String]? {
    if let a = params[key] as? [String] {
        return a.isEmpty ? nil : a
    }
    if let s = params[key] as? String {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.isEmpty ? nil : parts
    }
    return nil
}

/// v2.9.4：工具链路径解析 —— 以 "/" 开头视为绝对路径（如 Nyxian 系统 theos /usr/local/theos），
/// 否则按工作区相对路径 Workspace/<path> 解析。
func resolveToolchainPath(_ path: String) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    return Workspace.root.appendingPathComponent(path)
}

/// v2.9.4：解析后的工具链配置
struct ToolchainProfile {
    var isSystem: Bool          // 系统布局（越狱/Nyxian，clang 在 /usr/bin 等）
    var binDir: String?         // 规范布局的 bin 目录（prepend 到 PATH）；系统布局为 nil
    var clang: String           // clang 绝对路径（可能不存在，由前置检查判定）
    var make: String?           // make 绝对路径
    var perl: String?           // perl 绝对路径
    var ldid: String?           // ldid 绝对路径（可选）
    var theos: String           // theos 根目录
    var sdkDir: String?         // 探测到的 iOS SDK 目录
    var env: [String: String]   // 额外环境（PATH/THEOS/SDKROOT/TARGET）
    var rootPath: String        // 有效根目录（size/hint 用）
}

/// 按引用解析工具链："system" 或 "/" 走系统布局（越狱机 Nyxian），否则按规范布局（bin/theos/sdk）。
func resolveToolchainProfile(_ ref: String) -> ToolchainProfile {
    if ref == "system" || ref == "/" {
        return systemToolchainProfile()
    }
    let root = resolveToolchainPath(ref)
    let bin = root.appendingPathComponent("bin").path
    let theos = root.appendingPathComponent("theos").path

    // 规范布局 SDK 探测
    var sdk: String? = nil
    let sdkParent = root.appendingPathComponent("sdk").path
    if let cands = try? FileManager.default.contentsOfDirectory(atPath: sdkParent) {
        if let f = cands.filter({ $0.hasSuffix(".sdk") }).sorted().first {
            sdk = (sdkParent as NSString).appendingPathComponent(f)
        }
    }

    return ToolchainProfile(
        isSystem: false,
        binDir: bin,
        clang: (bin as NSString).appendingPathComponent("clang"),
        make: (bin as NSString).appendingPathComponent("make"),
        perl: (bin as NSString).appendingPathComponent("perl"),
        ldid: (bin as NSString).appendingPathComponent("ldid"),
        theos: theos,
        sdkDir: sdk,
        env: [
            "PATH": "\(bin):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/var/mobile",
            "THEOS": theos,
            "SDKROOT": sdk ?? "",
            "TARGET": "iphone:clang:latest:14.0"
        ],
        rootPath: root.path
    )
}

/// 系统布局（越狱机 Nyxian / rootless）：clang/make/perl/ldid 在系统路径，theos 在 /usr/local/theos。
private func systemToolchainProfile() -> ToolchainProfile {
    let fm = FileManager.default
    func firstExisting(_ paths: [String]) -> String? {
        paths.first { fm.fileExists(atPath: $0) }
    }
    let theos = firstExisting(["/var/jb/usr/local/theos", "/usr/local/theos", "/opt/theos"]) ?? "/usr/local/theos"
    let clang = firstExisting(["/var/jb/usr/bin/clang", "/usr/bin/clang", "/bin/clang"]) ?? "/usr/bin/clang"
    let make = firstExisting(["/var/jb/usr/bin/make", "/usr/bin/make", "/bin/make"]) ?? "/usr/bin/make"
    let perl = firstExisting(["/var/jb/usr/bin/perl", "/usr/bin/perl", "/bin/perl"]) ?? "/usr/bin/perl"
    let ldid = firstExisting(["/var/jb/usr/bin/ldid", "/usr/bin/ldid", "/usr/local/bin/ldid"]) ?? "/usr/bin/ldid"

    // SDK：theos/sdks 或 theos/sdk 下找 iPhoneOS*.sdk
    var sdk: String? = nil
    for parent in [(theos as NSString).appendingPathComponent("sdks"),
                   (theos as NSString).appendingPathComponent("sdk")] {
        if let cands = try? fm.contentsOfDirectory(atPath: parent) {
            if let f = cands.filter({ $0.hasSuffix(".sdk") }).sorted().first {
                sdk = (parent as NSString).appendingPathComponent(f)
                break
            }
        }
    }

    return ToolchainProfile(
        isSystem: true,
        binDir: nil,
        clang: clang,
        make: make,
        perl: perl,
        ldid: ldid,
        theos: theos,
        sdkDir: sdk,
        env: [
            "PATH": "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/var/mobile",
            "THEOS": theos,
            "SDKROOT": sdk ?? "",
            "TARGET": "iphone:clang:latest:14.0"
        ],
        rootPath: "/"
    )
}

// MARK: - 编译执行

/// build.run：编译 Workspace/projects/<project> 下的工程
///  - mode="theos"：cd 工程 && THEOS=<tc>/theos make [package]（产出 .dylib/.deb）
///  - mode="clang"：clang -arch arm64 -fobjc-arc -isysroot <sdk> -dynamiclib 编译 .c/.m/.mm
final class BuildRunTool: MCPTool {
    let definition = ToolDefinition(name: "build.run",
        summary: "编译工程（theos make 或裸 clang），返回退出码/输出/产物",
        parameters: [
            "project": "工程名（Workspace/projects/<project>）",
            "mode": "theos 或 clang（默认 theos）",
            "package": "theos 模式是否执行 make package 产出 .deb（true/false）",
            "clean": "编译前先 make clean（true/false）",
            "toolchain": "工具链路径：相对（toolchain = Workspace/toolchain）或绝对（/usr/local/theos 等系统路径）",
            "sdk": "SDK 名（可选，自动探测 toolchain/sdk/iPhoneOS*.sdk）",
            "output": "clang 模式产物文件名（默认 <project>.dylib）",
            "cflags": "clang 模式额外编译参数数组",
            "frameworks": "clang 模式链接框架数组（默认 Foundation）",
            "timeout": "超时秒数（默认 300）"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let project = params["project"] as? String ?? ""
        guard !project.isEmpty else { throw MCPError.invalidParams("project 必填") }
        let mode = params["mode"] as? String ?? "theos"
        let tcRel = params["toolchain"] as? String ?? "toolchain"
        let doPackage = boolParam(params, "package", false)
        let doClean = boolParam(params, "clean", false)
        let sdkName = params["sdk"] as? String ?? ""
        let timeout = doubleParam(params, "timeout", 300)

        let fm = FileManager.default
        let profile = resolveToolchainProfile(tcRel)
        let projectDir = Workspace.root.appendingPathComponent("projects/\(project)")
        let clangPath = profile.clang
        let theosDir = profile.theos
        let env = profile.env

        // ---- 前置检查 ----
        var problems: [String] = []
        var isDir: ObjCBool = false
        if !(fm.fileExists(atPath: projectDir.path, isDirectory: &isDir) && isDir.boolValue) {
            problems.append("工程目录不存在: \(projectDir.path)（先用 project.generate_tweak 或手动放置）")
        }
        if profile.isSystem {
            if !fm.fileExists(atPath: clangPath) {
                problems.append("系统 clang 不存在: \(clangPath)（越狱机需先装 Nyxian theos 工具链）")
            }
            if mode == "theos" && !(fm.fileExists(atPath: theosDir, isDirectory: &isDir) && isDir.boolValue) {
                problems.append("系统 theos 不存在: \(theosDir)（越狱机需先装 Nyxian theos）")
            }
        } else {
            if !(fm.fileExists(atPath: profile.rootPath, isDirectory: &isDir) && isDir.boolValue) {
                problems.append("工具链目录不存在: \(profile.rootPath)")
            }
            if !fm.fileExists(atPath: clangPath) {
                problems.append("clang 不存在: \(clangPath)")
            }
            if mode == "theos" && !(fm.fileExists(atPath: theosDir, isDirectory: &isDir) && isDir.boolValue) {
                problems.append("theos 目录不存在: \(theosDir)（mode=theos）")
            }
        }
        if !problems.isEmpty {
            return ["ok": false, "project": project, "mode": mode, "exit_code": -1,
                    "stdout": "", "stderr": problems.joined(separator: "\n"),
                    "artifacts": [String](), "duration_ms": 0]
        }

        // SDK 探测
        var sdkDir: String? = profile.sdkDir
        if !sdkName.isEmpty {
            sdkDir = profile.isSystem
                ? (theosDir as NSString).appendingPathComponent("sdks/\(sdkName)")
                : (profile.rootPath as NSString).appendingPathComponent("sdk/\(sdkName)")
        }
        // 若探测到 SDK 则注入 env
        var env2 = env
        if let sdk = sdkDir { env2["SDKROOT"] = sdk }

        let start = Date()
        var stdoutText = ""
        var stderrText = ""
        var exitCode: Int32 = -1
        var timedOut = false
        var artifacts: [String] = []

        if mode == "theos" {
            let makePath = profile.make ?? ""
            if makePath.isEmpty || !fm.fileExists(atPath: makePath) {
                return ["ok": false, "project": project, "mode": mode, "exit_code": -1,
                        "stdout": "", "stderr": "make 不存在: \(makePath)", "artifacts": [String](), "duration_ms": 0]
            }
            if doClean {
                let r = BuildRunner.shared.run(executable: makePath, args: ["clean"], workingDir: projectDir.path, env: env2, timeout: timeout)
                if r.exitCode != 0 {
                    stdoutText += r.stdout; stderrText += r.stderr
                }
            }
            var args = [String]()
            if doPackage { args.append("package") }
            let r = BuildRunner.shared.run(executable: makePath, args: args, workingDir: projectDir.path, env: env2, timeout: timeout)
            exitCode = r.exitCode; stdoutText = r.stdout; stderrText = r.stderr; timedOut = r.timedOut
            artifacts = collectArtifacts(projectDir.path)
        } else {
            // clang 模式
            let sources = collectSources(projectDir.path, exts: ["c", "m", "mm", "cpp", "cc"])
            if sources.isEmpty {
                return ["ok": false, "project": project, "mode": mode, "exit_code": -1,
                        "stdout": "", "stderr": "工程目录下没有 .c/.m/.mm/.cpp/.cc 源文件", "artifacts": [String](), "duration_ms": 0]
            }
            let outDir = projectDir.appendingPathComponent("build_out")
            try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            let outputName = params["output"] as? String ?? "\(project.lowercased()).dylib"
            let outputPath = outDir.appendingPathComponent(outputName).path

            var args = [String]()
            args += ["-arch", "arm64", "-fobjc-arc"]
            if let sdk = sdkDir {
                args += ["-isysroot", sdk, "-miphoneos-version-min=14.0"]
            }
            args.append("-dynamiclib")
            let cflags = stringArrayParam(params, "cflags")
            if let cflags = cflags {
                args += cflags
            }
            var frameworks = stringArrayParam(params, "frameworks") ?? ["Foundation"]
            if frameworks.isEmpty { frameworks = ["Foundation"] }
            for fw in frameworks {
                args += ["-framework", fw]
            }
            args += sources
            args += ["-o", outputPath]

            let r = BuildRunner.shared.run(executable: clangPath, args: args, workingDir: projectDir.path, env: env, timeout: timeout)
            exitCode = r.exitCode; stdoutText = r.stdout; stderrText = r.stderr; timedOut = r.timedOut
            if fm.fileExists(atPath: outputPath) { artifacts = [outputPath] }
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        AuditLog.shared.log("build.run", detail: "\(project) mode=\(mode) exit=\(exitCode) artifacts=\(artifacts.count)")

        return [
            "ok": exitCode == 0,
            "project": project,
            "mode": mode,
            "exit_code": Int(exitCode),
            "timed_out": timedOut,
            "timeout_seconds": Int(timeout),
            "stdout": stdoutText,
            "stderr": stderrText,
            "artifacts": artifacts,
            "duration_ms": durationMs
        ]
    }

    private func collectSources(_ dir: String, exts: [String]) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        var result: [String] = []
        for case let rel as String in en {
            let ext = (rel as NSString).pathExtension.lowercased()
            if exts.contains(ext) {
                result.append((dir as NSString).appendingPathComponent(rel))
            }
        }
        return result.sorted()
    }

    private func collectArtifacts(_ projectDir: String) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        let searchDirs = [
            (projectDir as NSString).appendingPathComponent(".theos/obj/debug"),
            (projectDir as NSString).appendingPathComponent(".theos/obj"),
            (projectDir as NSString).appendingPathComponent(".theos/_/debs")
        ]
        for d in searchDirs {
            if let files = try? fm.contentsOfDirectory(atPath: d) {
                for f in files where f.hasSuffix(".dylib") || f.hasSuffix(".deb") {
                    found.append((d as NSString).appendingPathComponent(f))
                }
            }
        }
        if let files = try? fm.contentsOfDirectory(atPath: projectDir) {
            for f in files where f.hasSuffix(".deb") {
                found.append((projectDir as NSString).appendingPathComponent(f))
            }
        }
        return Array(Set(found)).sorted()
    }
}
