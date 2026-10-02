//
//  InstallTools.swift
//  v4.3.65：统一工具安装入口 —— AI 自动搜索并安装工具/依赖的闭环
//
//  tool.install：AI 想要某个工具时一键安装：
//    1. 已就绪？—— 内置原生 iOS bin（Resources/bin）/ Alpine 已有
//    2. Alpine 包（apk add，即装即用，可 bind 直读 iOS 文件）
//    3. 原生 iOS 二进制 → 触发 CI 交叉编译（build-tool.yml）→ github.download_artifact 取产物
//  env.setup_re：一键逆向工具链（逆向 iOS/App/IPA 常用 Alpine 工具批装）
//

import Foundation

final class ToolInstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "tool.install",
        summary: "Unified tool installer: search & install tools/dependencies automatically. Use for: AI needs a tool not yet available — checks builtin native bin, then Alpine apk (instant, can read iOS files via auto-bind), then triggers CI cross-compile for native iOS binaries (best-effort). Don't use for: build a tweak (use github.trigger_build), load dylib into apps (use inject). Examples: tool.install name:jq → apk add jq; tool.install name:jtool2 → CI 交叉编译原生 iOS 二进制; tool.install profile:re → 逆向工具链批装.",
        parameters: [
            "name": "Tool name to install (e.g. jq / jtool2 / class-dump)",
            "profile": "Optional curated batch: re(逆向工具链) / dev(开发环境) / network(网络工具)",
            "source": "Optional GitHub repo URL for native iOS CI build (e.g. https://github.com/Neurotycho/jtool2)"
        ],
        verified: true, category: "build")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // 1. profile 批量安装
        if let profile = params["profile"] as? String {
            let p = profile.lowercased().trimmingCharacters(in: .whitespaces)
            if let batch = Self.profiles[p] {
                return installBatch(batch, profile: p)
            }
            // 未知 profile：不直接报错——AI 可能把 pandas 这类包名误传成 profile，
            // 把它当作普通工具名继续走 name 安装流程。
            var sub = params
            sub["profile"] = nil
            sub["name"] = p
            return installByName(p, params: sub)
        }
        guard let rawName = params["name"] as? String else {
            throw MCPError.invalidParams("name or profile required")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { throw MCPError.invalidParams("name required") }
        return installByName(name, params: params)
    }

    // MARK: - 按名单个安装（内置 → Alpine apk → pip → CI）

    private func installByName(_ name: String, params: [String: Any]) -> [String: Any] {
        // 1. 已就绪？——内置原生 bin / Alpine 已有
        // v4.4.9-fix3bv: 就绪≠可用——二进制存在/apk exit 0 都可能是"装了但调不动/输出不可见"
        // (pandas 误报、python3/r2 空输出、BusyBox tree 缺参数)。统一冒烟：命令名调 --version/-v/--help/-h，
        // 验证 exit 0 且输出可见；异常则在 hint 里明确提示（不静默报 ready）。
        if let bundled = bundledBinPath(name) {
            let (ok, note) = smokeTest(name)
            return ["ok": true, "tool": name, "status": "ready", "source": "builtin_native", "path": bundled,
                    "hint": "App 内置原生 iOS 二进制；" + note]
        }
        let which = ISHEngine.exec("which \(name) 2>/dev/null", timeout: 30)
        if which.exitCode == 0 {
            let path = which.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? name
            let (ok, note) = smokeTest(name)
            return ["ok": true, "tool": name, "status": ok ? "ready" : "unverified", "source": "alpine", "path": path,
                    "hint": "Alpine 已有；命令引用 iOS 路径会自动 bind 直读（/ios_workspace、/ios_containers、/ios_system 只读）。" + note]
        }

        // 2. Alpine apk 安装：依次尝试候选包名（映射名 / 原名 / py3-xxx）。
        //    v4.3.69：统一走 ISHEngine.apkAdd（自动切国内镜像源 + 补 ca-certificates，修官方源
        //    在手机网络被断导致索引拉不下→误报 no such package；大包 240s 超时，避免 20s 被掐）
        var lastApkErr = ""
        for pkg in apkCandidates(for: name) {
            // v4.3.75：进度条 + 失败结构化诊断
            InstallationRegistry.shared.start(key: pkg)
            let apk = ISHEngine.apkAdd([pkg], timeout: 240) { line in
                InstallationRegistry.shared.appendLine(line)
            }
            if apk.exitCode == 0 {
                InstallationRegistry.shared.finish(ok: true, summary: "已装 \(pkg)")
                let isPy = pkg.hasPrefix("py3-") || Self.pythonHints.contains(name)
                let (ok, note) = smokeTest(name, importMode: isPy)
                return ["ok": true, "tool": name, "status": ok ? "installed" : "installed_unverified", "source": "alpine_apk", "package": pkg,
                        "hint": "已 apk add \(pkg)（" + note + "）。直接调用 `\(name) <参数>` 即可——shell.exec 会自动路由 Alpine 并 bind 直读 iOS 路径（如 \(name) /var/mobile/xxx 自动改 /ios_mobile/xxx）；缺依赖时首次调用会自动补齐。若冒烟异常：先 `\(name) --help` 看用法；仍无输出用文件重定向验证（`\(name) ... > /tmp/x; cat /tmp/x`）"]
            }
            InstallationRegistry.shared.finish(ok: false, summary: ISHEngine.installDiagnose(apk.output, timedOut: apk.timedOut, exitCode: apk.exitCode))
            lastApkErr = apk.output
            // 「找不到包」才继续试下一个候选；网络/磁盘等错误也继续，最终由兜底提示
        }
        let pkgNotFound = lastApkErr.contains("unable to select package") || lastApkErr.contains("No such package")

        // 3. Python 包回退：确保 python3 + pip，再 pip install
        if Self.pythonHints.contains(name) || name.hasPrefix("py-") {
            InstallationRegistry.shared.start(key: "python3 py3-pip")
            let apkPy = ISHEngine.apkAdd(["python3", "py3-pip"], timeout: 240) { line in
                InstallationRegistry.shared.appendLine(line)
            }
            if apkPy.exitCode != 0 {
                let diag = ISHEngine.installDiagnose(apkPy.output, timedOut: apkPy.timedOut, exitCode: apkPy.exitCode)
                InstallationRegistry.shared.finish(ok: false, summary: diag)
                return ["ok": false, "tool": name, "status": "failed", "source": "alpine_apk",
                        "error": "python3/pip 安装失败", "hint": diag]
            }
            let pipName = name.hasPrefix("py-") ? String(name.dropFirst(3)) : name
            InstallationRegistry.shared.start(key: "pip install \(pipName)")
            // v4.4.9-fix3ca: pip 换清华镜像(国内快/稳，官方源慢断)+内部超时——Alpine pip 装包不再卡
            let pip = ISHEngine.exec("pip install --break-system-packages --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple --timeout 60 \(pipName)", timeout: 480) { line in
                InstallationRegistry.shared.appendLine(line)
            }
            if pip.exitCode == 0 {
                InstallationRegistry.shared.finish(ok: true, summary: "pip 已装 \(pipName)")
                let (ok, note) = smokeTest(pipName, importMode: true)
                return ["ok": true, "tool": name, "status": ok ? "installed" : "installed_unverified", "source": "pip",
                        "hint": "已 pip install \(pipName)（" + note + "）。调用必须 `sh -c 'python3 -c ...'` 强制 Alpine（命令名 python3 走原生看不到 Alpine 包）；iSH 上含 C 扩展的包较慢，优先用 apk 的 py3- 预编译版"]
            }
            InstallationRegistry.shared.finish(ok: false, summary: ISHEngine.installDiagnose(pip.output, timedOut: pip.timedOut, exitCode: pip.exitCode))
            lastApkErr = pip.output
        }

        // 4. 原生 iOS 二进制 → CI 交叉编译（build-tool.yml）
        if pkgNotFound || Self.nativeRegistry.keys.contains(name) || params["source"] != nil {
            let source = (params["source"] as? String) ?? Self.nativeRegistry[name]?.source
            if let src = source, !src.isEmpty {
                guard let token = GHConfig.activeToken else {
                    return ["ok": false, "tool": name, "status": "ci_blocked",
                            "error": "Alpine 无此包且未登录 GitHub（无法触发 CI 交叉编译）",
                            "hint": "原生 iOS 二进制只能走三条通道：内置 bin / CI 交叉编译(github.trigger_build) / 自写 dylib(inject load_dylib)。请先在 设置-GitHub 账号 登录后重试"]
                }
                var body: [String: Any] = ["ref": GHConfig.branch]
                body["inputs"] = ["name": name, "source": src]
                let (code, json) = GHAPI.post(
                    "\(GHConfig.apiBase)/repos/\(GHConfig.repoOwner)/\(GHConfig.repoName)/actions/workflows/build-tool.yml/dispatches",
                    token: token, body: body)
                if code == 204 {
                    return ["ok": true, "tool": name, "status": "ci_triggered", "workflow": "build-tool.yml", "source": src,
                            "next": "几十秒后 github.fetch_runs 查进度；成功后 github.download_artifact 取产物（解压在 Workspace/downloads/run_<id>/）",
                            "note": "best-effort：Makefile 类工程可直接交叉编译；若 artifact 为空请用 PC 交叉编译或改走自写 dylib"]
                }
                return ["ok": false, "tool": name, "status": "ci_failed", "http_status": code,
                        "message": (json?["message"] as? String) ?? "trigger failed"]
            }
        }

        // 5. 兜底指引
        return ["ok": false, "tool": name, "status": "not_found",
                "hint": "Alpine 无此包（试了 \(apkCandidates(for: name).joined(separator: "/"))）。可尝试：① tool.install profile:re（逆向工具链批装）；② 提供 source 仓库 URL 走 CI 交叉编译（原生 iOS 二进制）；③ shell.exec('apk search \(name)') 找近似包名；④ 自写工具 inject load_dylib"]
    }

    /// Alpine 候选包名：映射名 → 原名 → py3-xxx（Python 包在 Alpine 多为 py3- 前缀）
    /// v4.4.9-fix3bv: 冒烟测试——命令名调用 --version/-v/--help/-h，验证 exit 0 且输出可见。
    /// 治"装了但不可用"：apk exit 0 但包没进当前环境（pandas 误报）、stdout 缓冲空输出（python3/r2）、
    /// 精简版缺参数（BusyBox tree -L）。返回 (ok, 可读说明)。
    private func smokeTest(_ name: String, importMode: Bool = false) -> (ok: Bool, note: String) {
        // python 包（pip/apk py3- 装的）：包只在 Alpine python 可见——命令名 python3 走 iOS 原生看不到
        // （pandas 误报根源）→ sh -c 强制 Alpine + import 验证；import 成功打印 OK 供输出可见判断
        if importMode {
            let safe = name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
            do {
                let r = try ShellExecTool().invoke(["command": "sh -c 'python3 -c \"import \(safe); print(\"IMPORT_OK \" + \(safe).__name__)\"'", "timeout": 30])
                let out = (r["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let exit = r["exit_code"] as? Int ?? 1
                if exit == 0 && out.contains("IMPORT_OK") {
                    return (true, "Alpine python 冒烟 `import \(safe)` OK（" + String(out.prefix(60)) + "）——注意：调用必须用 `sh -c 'python3 ...'` 强制 Alpine（命令名 python3 走原生看不到 Alpine 包）")
                }
                let errNote = out.isEmpty ? "无输出" : String(out.prefix(80))
                return (false, "Alpine python `import \(safe)` 失败（exit \(exit)：" + errNote + "）——包可能没装进 Alpine python，或 C 扩展在 iSH 段错误（numpy/pandas 用原生 python，已内置）")
            } catch {
                return (false, "Alpine python `import \(safe)` 冒烟异常：\(error)")
            }
        }
        for flag in ["--version", "-v", "--help", "-h"] {
            do {
                let r = try ShellExecTool().invoke(["command": "\(name) \(flag)", "timeout": 20])
                let out = (r["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let exit = r["exit_code"] as? Int ?? 1
                if exit == 0 && !out.isEmpty {
                    let first = out.split(separator: "\n").first.map(String.init) ?? ""
                    return (true, "冒烟验证 `\(name) \(flag)` OK（" + String(first.prefix(90)) + "）")
                }
                if exit == 0 && out.isEmpty {
                    return (false, "冒烟 `\(name) \(flag)` exit 0 但无输出——stdout 缓冲/捕获问题，工具可能"装了但结果不可见"；调用后若空输出请用 `> /tmp/x; cat /tmp/x` 重定向验证")
                }
            } catch { }
        }
        return (false, "冒烟 `\(name) --version/-v/--help/-h` 全部失败——工具可能装了但不可调用，或该工具无版本/帮助参数；先用 `\(name) --help` 看真实用法")
    }

    private func apkCandidates(for name: String) -> [String] {
        var out: [String] = []
        if let mapped = Self.alpineNameMap[name] { out.append(mapped) }
        out.append(name)
        if name != "python" && name != "python3" && !name.hasPrefix("py3-") {
            out.append("py3-\(name)")
        }
        var seen = Set<String>(); return out.filter { seen.insert($0).inserted }
    }

    // MARK: - 批量安装（profile）

    private func installBatch(_ pkgs: [String], profile: String) -> [String: Any] {
        var results: [[String: Any]] = []
        var okCount = 0
        for pkg in pkgs {
            // v4.3.77：用户已停止 → 跳出，不再装剩余包
            if ConversationStore.shared.stopRequested { break }
            // v4.3.77：批量安装也走进度条（每包独立进度），不再静默
            InstallationRegistry.shared.start(key: pkg)
            let r = ISHEngine.apkAdd([pkg], timeout: 240) { line in
                InstallationRegistry.shared.appendLine(line)
            }
            let ok = r.exitCode == 0
            if ok { okCount += 1 }
            InstallationRegistry.shared.finish(ok: ok,
                summary: ok ? "已装 \(pkg)" : ISHEngine.installDiagnose(r.output, timedOut: r.timedOut, exitCode: r.exitCode))
            let detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").suffix(2).joined(separator: "\n")
            results.append(["package": pkg, "ok": ok, "detail": detail])
        }
        return ["ok": okCount == pkgs.count, "profile": profile,
                "installed": okCount, "total": pkgs.count, "results": results,
                "hint": "装的是 Alpine(Linux) 工具：可 bind 直读 iOS 文件，但无法编译/注入原生 iOS 二进制（那类走 tool.install name:jtool2 触发 CI）"]
    }

    // MARK: - 查找内置原生 bin

    /// v4.3.69：修复 pandas 等包被误判"内置已就绪"的 bug——实测 isExecutableFile 对【目录】
    /// 也返回 true，会把 bin 目录误当内置二进制而短路安装流程。修复：①必须存在且非目录才命中；
    /// ②Python 包（pythonHints / py3- 映射）根本不走内置检查（内置 bin 只有 iOS 原生工具，无 Python 包）。
    private func bundledBinPath(_ name: String) -> String? {
        if Self.pythonHints.contains(name)
            || Self.alpineNameMap[name]?.hasPrefix("py3-") == true {
            return nil
        }
        let roots = [
            Bundle.main.bundlePath + "/Resources/bin",
            Bundle.main.bundlePath + "/bin"
        ]
        for root in roots {
            let candidates = [
                root + "/" + name,
                root + "/" + name + "_ios",
                root + "/" + name + "-ios"
            ]
            for c in candidates {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: c, isDirectory: &isDir),
                      !isDir.boolValue,
                      FileManager.default.isExecutableFile(atPath: c) else { continue }
                return c
            }
        }
        return nil
    }

    // MARK: - 静态数据

    /// 常用工具名 → Alpine 包名映射（nm/strings 等常见名在 Alpine 里归属 binutils）
    private static let alpineNameMap: [String: String] = [
        "nm": "binutils", "strings": "binutils", "objdump": "binutils", "readelf": "binutils",
        "python": "python3", "sqlite3": "sqlite", "7z": "7zip",  // v4.3.77: Alpine 包名 7zip
        "node": "nodejs", "make": "make", "cmake": "cmake",
        "nc": "netcat-openbsd", "dig": "bind-tools", "nslookup": "bind-tools",
        "tcpdump": "tcpdump", "nmap": "nmap", "wget": "wget",
        "xxd": "xxd", "tree": "tree", "vim": "vim", "gawk": "gawk",
        "zip": "zip", "unzip": "unzip", "xz": "xz", "file": "file",
        "curl": "curl", "git": "git", "jq": "jq", "openssl": "openssl",
        "gcc": "gcc", "clang": "clang", "gdb": "gdb",
        // 常见 Python 包（Alpine 预编译，py3- 前缀）
        "pandas": "py3-pandas", "numpy": "py3-numpy", "scipy": "py3-scipy",
        "requests": "py3-requests", "matplotlib": "py3-matplotlib", "pillow": "py3-pillow",
        "flask": "py3-flask", "django": "py3-django", "pip": "py3-pip",
        "bs4": "py3-beautifulsoup4", "beautifulsoup4": "py3-beautifulsoup4",
        "openpyxl": "py3-openpyxl", "pytest": "py3-pytest", "yaml": "py3-yaml",
        "sqlalchemy": "py3-sqlalchemy", "cryptography": "py3-cryptography"
    ]

    /// 常见 Python 包名：apk 无对应 py3- 包时，回退到 pip install
    private static let pythonHints: Set<String> = [
        "pandas", "numpy", "scipy", "requests", "matplotlib", "pillow", "flask",
        "django", "bs4", "beautifulsoup4", "openpyxl", "pytest", "sqlalchemy",
        "cryptography", "pyyaml", "aiohttp", "tornado", "click", "six"
    ]

    /// 逆向/开发/网络 三档 curated 批量（Alpine 包）
    private static let profiles: [String: [String]] = [
        "re": ["binutils", "file", "python3", "sqlite", "openssl", "curl", "git", "jq",
               "zip", "unzip", "xz", "7zip", "tree", "gawk", "coreutils", "findutils", "vim",
               "tcpdump", "netcat-openbsd"],
        "dev": ["build-base", "git", "python3", "vim", "curl", "jq", "cmake", "nodejs"],
        "network": ["curl", "wget", "jq", "openssl", "ca-certificates", "bind-tools", "tcpdump"]
    ]

    /// 原生 iOS 二进制注册表（Alpine 没有，走 CI 交叉编译；note 说明真实可行性）
    private static let nativeRegistry: [String: (source: String, note: String)] = [
        "jtool2": ("https://github.com/Neurotycho/jtool2",
                   "Makefile 工程，best-effort 交叉编译；输出 jtool（Mach-O 深度分析），iOS 逆向标配"),
        "class-dump": ("https://github.com/stevemacarthur/class-dump",
                       "macOS Makefile，iOS 交叉编译需改 SDK 目标；若 artifact 为空请 PC 编译后自写 dylib 包装"),
        "frida-server": ("https://github.com/frida/frida",
                         "需要越狱/内核信任，TrollStore 下通常不可用；不建议，仅列出说明边界")
    ]
}

/// v4.3.65：一键逆向工具链（env.setup_re = tool.install profile:re）
final class EnvSetupRETool: MCPTool {
    let definition = ToolDefinition(
        name: "env.setup_re",
        summary: "One-click reverse-engineering toolchain for iOS/App/IPA analysis (Alpine batch install). Use for: AI needs RE tools (strings/file/nm/python3/sqlite/tcpdump/7z...). Don't use for: native iOS binaries (jtool2/class-dump → use tool.install name:jtool2). Example: 'setup reverse engineering tools' → install curated RE batch.",
        parameters: [:],
        verified: true, category: "build")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return try ToolInstallTool().invoke(["profile": "re"])
    }
}
