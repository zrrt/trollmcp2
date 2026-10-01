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
        if let bundled = bundledBinPath(name) {
            return ["ok": true, "tool": name, "status": "ready", "source": "builtin_native", "path": bundled,
                    "hint": "App 内置原生 iOS 二进制，可直接用于 iOS 文件分析与注入"]
        }
        let which = ISHEngine.exec("which \(name) 2>/dev/null", timeout: 30)
        if which.exitCode == 0 {
            let path = which.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? name
            return ["ok": true, "tool": name, "status": "ready", "source": "alpine", "path": path,
                    "hint": "Alpine 已有；命令引用 iOS 路径会自动 bind 直读（/ios_workspace、/ios_containers、/ios_system 只读）"]
        }

        // 2. Alpine apk 安装：依次尝试候选包名（映射名 / 原名 / py3-xxx）
        var lastApkErr = ""
        for pkg in apkCandidates(for: name) {
            let apk = ISHEngine.exec("apk add --no-cache \(pkg)", timeout: 240)
            if apk.exitCode == 0 {
                return ["ok": true, "tool": name, "status": "installed", "source": "alpine_apk", "package": pkg,
                        "hint": "已 apk add \(pkg)；Alpine 工具可 bind 直读 iOS 文件（无 2MB 限制）"]
            }
            lastApkErr = apk.output
            // 「找不到包」才继续试下一个候选；网络/磁盘等错误也继续，最终由兜底提示
        }
        let pkgNotFound = lastApkErr.contains("unable to select package") || lastApkErr.contains("No such package")

        // 3. Python 包回退：确保 python3 + pip，再 pip install
        if Self.pythonHints.contains(name) || name.hasPrefix("py-") {
            ISHEngine.exec("apk add --no-cache python3 py3-pip", timeout: 240)
            let pipName = name.hasPrefix("py-") ? String(name.dropFirst(3)) : name
            let pip = ISHEngine.exec("pip install --break-system-packages --no-cache-dir \(pipName)", timeout: 300)
            if pip.exitCode == 0 {
                return ["ok": true, "tool": name, "status": "installed", "source": "pip",
                        "hint": "已 pip install \(pipName)；iSH 上含 C 扩展的包较慢，优先用 apk 的 py3- 预编译版"]
            }
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
            let r = ISHEngine.exec("apk add --no-cache \(pkg)", timeout: 180)
            let ok = r.exitCode == 0
            if ok { okCount += 1 }
            let detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").suffix(2).joined(separator: "\n")
            results.append(["package": pkg, "ok": ok, "detail": detail])
        }
        return ["ok": okCount == pkgs.count, "profile": profile,
                "installed": okCount, "total": pkgs.count, "results": results,
                "hint": "装的是 Alpine(Linux) 工具：可 bind 直读 iOS 文件，但无法编译/注入原生 iOS 二进制（那类走 tool.install name:jtool2 触发 CI）"]
    }

    // MARK: - 查找内置原生 bin

    private func bundledBinPath(_ name: String) -> String? {
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
            for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
                return c
            }
        }
        return nil
    }

    // MARK: - 静态数据

    /// 常用工具名 → Alpine 包名映射（nm/strings 等常见名在 Alpine 里归属 binutils）
    private static let alpineNameMap: [String: String] = [
        "nm": "binutils", "strings": "binutils", "objdump": "binutils", "readelf": "binutils",
        "python": "python3", "sqlite3": "sqlite", "7z": "p7zip",
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
               "zip", "unzip", "xz", "p7zip", "tree", "gawk", "coreutils", "findutils", "vim",
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
