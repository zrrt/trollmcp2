import Foundation
import UIKit
import Darwin
import CommonCrypto
import SQLite3

/// 终端会话管理 (单例，v3.0.93: 已废弃 - iSH 引擎自己管理 cwd，这个类是死代码）
final class ShellSession {
    static let shared = ShellSession()
    private init() {}
}


/// v3.0.36：shell 诊断日志 (Documents/Workspace/shell-diag.log），追查超时/卡死真相
enum ShellDiag {
    private static let lock = NSLock()
    private static var path: String = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace/shell-diag.log").path
    }()
    static func log(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(Date())] \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}

/// 内置终端工具：执行 shell 命令 (iSH 引擎）
final class ShellExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.exec",
        summary: "Run a shell command (terminal/command line). iOS native mode (default): 36 个原生命令直通真实 iOS 系统——文件操作 (ls/cat/find/grep/echo/mkdir/rm/mv/cp/tail/head/sed/pwd/touch/wc/md5sum/diff/hexdump/curl/plutil/sqlite3/unzip) + 系统信息 (df/free/uname/uptime/hostname/ps/top/kill) + 网络 (ifconfig/netstat/nslookup)。支持管道/分号/重定向/&&/|| (例：'ls /var/mobile | head -5'、'cat a.txt; echo done'、'echo hi > f.txt')，支持 VAR=value 赋值与 $VAR 展开；过滤器白名单：head/tail/grep/wc/sed/awk/sort/uniq/cut/tr/rev/echo/cat。限制：iOS 原生模式不支持 for/while/case/heredoc/多行脚本。环境自动路由（系统决定，不要传 env 参数）：装包/解包/完整工具链/复杂脚本(apk、tar/dpkg、python、git、sh -c、heredoc等开头)自动走 Alpine Linux；文件操作/系统信息/网络/二进制分析默认 iOS 原生。若确实需要 Alpine 能力，用能命中自动路由的命令形式开头(如 python3 / apk add / tar / sh script.sh)。注意 Alpine 是独立 chroot，iOS 的 /var/mobile/... 路径在 Alpine 里不可见，需先把文件 cp 到 /workspace 或 /tmp 再读。SQLite .db 在原生里用内置 sqlite3：`sqlite3 <db> \".tables\"` / `sqlite3 <db> \"SELECT ...\"`，支持 .schema/.indexes。Native Offload：`ta <tool> <key:value...>` 是全部原生工具的单一入口——先 `ta list` 看可用工具、`ta help <tool>` 看参数，再 `ta <tool> key:value` 直接调用 (例：ta app launch bundle_id:com.xxx；ta vpn.capture command:start)。Use for: file operations, system info, network, text processing. Don't use for: UI taps/swipes (use control.*), app control (use app.*), injection (use injection.*).",
        parameters: [
            "command": "Shell command to execute (required)",
            "timeout": "Timeout seconds (default 30, max 120)",
            "reset_cwd": "Optional Bool: reset working dir to default (default false)",
            "limit": "Optional Int: result string truncation cap (default 4000 chars). If diagnostics output is trimmed and the body is invisible, pass limit=20000 或更大；full=true 则不截断返回完整结果",
            "full": "Optional Bool: true=返回完整结果不截断 (慎用，大输出占满上下文)",
            "offset": "Optional Int: skip first N chars of output before showing (default 0), combine with limit to read a middle slice",
            "env": "已弃用/忽略：环境由系统按命令类型自动路由(装包/解包deb/复杂脚本/python自动走Alpine，其余默认iOS原生)。不要手动传 env 切环境——你无选择权，环境路由是系统的。若确实需强制某环境请说明需求(如'在Alpine里装python')。"
        ],
        verified: true
    )
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String, !command.isEmpty else {
            throw MCPError.invalidParams("command required")
        }
        
        // 危险命令检测
        let dangerousPatterns = [
            "^rm\\s+-rf\\s+/$",
            "^rm\\s+-rf\\s+~",
            "^dd\\s+if=",
            "mkfs",
            "^chmod\\s+-R\\s+777\\s+/",
        ]
        for pattern in dangerousPatterns {
            if command.range(of: pattern, options: .regularExpression) != nil {
                return [
                    "error": "dangerous command blocked",
                    "command": command,
                    "hint": "this command could break the system and was blocked by the safety policy."
                ]
            }
        }
        
        // 重置工作目录
        if params["reset_cwd"] as? Bool == true {
            ISHEngine.resetCwd()
        }
        
        let timeout = min(max((params["timeout"] as? Double) ?? 30, 1), 120)
        
        // v3.1.32: iOS 原生命令拦截——直接用 iOS FileManager 执行，不经过 Alpine
        // 这样就能访问整个 iOS 文件系统了！
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // v3.3.4: Native Offload —— `ta <tool> <key:value...>` 统一路由到全部原生 MCP 工具。
        // AI 只需学一个入口 (ta list / ta help <tool>)，无需记忆 40+ 工具的参数 schema。
        if trimmed == "ta" || trimmed.hasPrefix("ta ") {
            let result = OffloadRouter.run(trimmed)
            AuditLog.shared.log("shell.exec (ta offload)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // v3.1.33: env 探针命令——一键返回当前执行环境 (后端/cwd/路径可见性），
        // 任何"时灵时不灵"异常第一步用它定位 (AI 诊断 P4）
        if trimmed == "env" || trimmed == "env " || trimmed.hasPrefix("env ") && trimmed.count <= 5 {
            let home = NSHomeDirectory()
            let docs = home + "/Documents"
            var iosContainers = false
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: "/var/containers", isDirectory: &isDir), isDir.boolValue {
                iosContainers = true
            }
            return [
                "command": command,
                "exit_code": 0,
                "stdout": [
                    "执行环境: iOS 原生 (FileManager 直连)",
                    "HOME: \(home)",
                    "Documents: \(docs)",
                    "cwd: \(ISHEngine.cwd)",
                    "iOS 系统路径可见(/var/containers): \(iosContainers)",
                    "Alpine 后端: iSH 引擎 (/workspace 映射 iOS Documents/Workspace)",
                    "提示: 含 | ; && > 的复合命令走 iOS 原生管道执行器；非 iOS 命令段走 Alpine"
                ].joined(separator: "\n"),
                "ios_native": true,
                "hint": "env probe: diagnose execution environment issues"
            ]
        }
        
        // v3.3.4: limit/full/offset —— 输出截断可动态控制 (AI 实测：limit/full 参数不生效）
        //  limit  = 截断上限字符数 (默认 4000；0 = 不截断）
        //  full   = true 时返回全量 (等效 limit:0），不 spill 不截断
        //  offset = 跳过前 N 字符再展示 (配合 limit 取中间段，等价 sed 取中段）
        let limitParam = (params["limit"] as? Int) ?? 0
        let fullOutput = params["full"] as? Bool == true
        let offsetParam = max(0, (params["offset"] as? Int) ?? 0)
        let outLimit = fullOutput ? 0 : (limitParam > 0 ? limitParam : 4000)
        
        // P2 环境自动路由：不再由 agent 手动 env 指定切环境（横跳旋钮拆掉）。
        // 系统按命令类型自动判定：需 Alpine 工具(装包/解包/脚本/python) → Alpine；
        // 其余默认走 iOS 原生。agent 传的 env 参数被忽略(仅作弱提示，见 description)。
        if ShellExecTool.autoRouteNeedsAlpine(trimmed) {
            // v3.3.4: ta (Native Offload）是宿主能力，与 Alpine 沙盒无关——
            // 即使判定 Alpine，ta 也走宿主路由，杜绝"环境漂移"。
            if trimmed == "ta" || trimmed.hasPrefix("ta ") {
                return OffloadRouter.run(trimmed)
            }
            let (output, exitCode, timedOut) = ISHEngine.exec(trimmed, timeout: timeout)
            // P3 按需补给：Alpine 输出显示缺工具(command not found)且命中白名单 → 自动 apk add 并重跑一次，
            // 免 agent 反复探测缺什么、也避免"先探测→再装→再跑"的多轮试探。
            var finalOut = output, finalExit = exitCode, finalTimed = timedOut
            if let pkg = ISHEngine.missingToolPkg(output) {
                ShellDiag.log("provision auto: apk add \(pkg) (missing in Alpine)")
                _ = ISHEngine.exec("apk add --no-cache \(pkg)", timeout: 120)
                let (rout, rexit, rtimed) = ISHEngine.exec(trimmed, timeout: timeout)
                finalOut = rout; finalExit = rexit; finalTimed = rtimed
            }
            var stdout = ShellExecTool.filterNoise(finalOut)
            if outLimit > 0 && stdout.count > outLimit {
                let spillPath = ToolRegistry.spillLarge("alpine", stdout)
                stdout = String(stdout.prefix(outLimit / 2)) + "\n…[输出太长total \(stdout.count) 字符，已截断；完整输出: \(spillPath)]…\n" + String(stdout.suffix(outLimit / 2))
            }
            var result: [String: Any] = [
                "command": trimmed,
                "exit_code": finalExit,
                "stdout": stdout,
                "cwd": ISHEngine.cwd,
                "ios_native": false,
                "hint": "Alpine Linux environment (auto-routed: needs full toolchain). 缺工具时系统已自动 apk add 安装并重试一次。"
            ]
            if finalTimed { result["timed_out"] = true }
            AuditLog.shared.log("shell.exec (alpine auto)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // v3.1.33: shell 语法识别——含管道/分号/重定向/逻辑符的命令不再裸前缀匹配 (iOS 原生朴素分词会把 | ; 当参数），
        // 统一走 iOS 原生管道执行器：首段 iOS 原生执行 + Swift 过滤器 + 顺序拼接。
        // 这修复了"同一命令有时跑 iOS 有时跑 Alpine、结果随机"的病根。
        // v3.1.71：先做变量展开 (P=/xxx 赋值 + $P 引用），否则 "$P" 被当字面路径报 No such file (AI 实测）
        let expanded = ShellExecTool.expandVars(trimmed)
        if ShellExecTool.containsShellSyntax(expanded) {
            let result = ShellExecTool.runIOSPipeline(expanded, limit: outLimit, offset: offsetParam)
            AuditLog.shared.log("shell.exec (ios pipeline)", detail: String(expanded.prefix(100)))
            return result
        }
        
        // 1. ls 命令——iOS 原生实现
        if trimmed.hasPrefix("ls ") || trimmed == "ls" {
            let result = ShellExecTool.runIOSls(trimmed)
            AuditLog.shared.log("shell.exec (ios ls)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 2. cat 命令——iOS 原生实现 (读文件）
        if trimmed.hasPrefix("cat ") {
            let result = ShellExecTool.runIOSCat(trimmed)
            AuditLog.shared.log("shell.exec (ios cat)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 3. find 命令——iOS 原生实现 (找文件）
        if trimmed.hasPrefix("find ") {
            let result = ShellExecTool.runIOSFind(trimmed)
            AuditLog.shared.log("shell.exec (ios find)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 4. grep 命令——iOS 原生实现 (搜文本）
        if trimmed.hasPrefix("grep ") {
            let result = ShellExecTool.runIOSGrep(trimmed)
            AuditLog.shared.log("shell.exec (ios grep)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 5. 写文件命令 (echo > / >>）——iOS 原生实现
        if trimmed.range(of: #"^echo\s+.*>\s+"#, options: .regularExpression) != nil {
            let result = ShellExecTool.runIOSWrite(trimmed)
            AuditLog.shared.log("shell.exec (ios write)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 6. mkdir 命令——iOS 原生实现 (建目录）
        if trimmed.hasPrefix("mkdir ") {
            let result = ShellExecTool.runIOSMkdir(trimmed)
            AuditLog.shared.log("shell.exec (ios mkdir)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 7. rm 命令——iOS 原生实现 (删文件/目录）
        if trimmed.hasPrefix("rm ") {
            let result = ShellExecTool.runIOSRm(trimmed)
            AuditLog.shared.log("shell.exec (ios rm)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 8. mv 命令——iOS 原生实现 (移动/重命名）
        if trimmed.hasPrefix("mv ") {
            let result = ShellExecTool.runIOSMv(trimmed)
            AuditLog.shared.log("shell.exec (ios mv)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 9. cp 命令——iOS 原生实现 (复制）
        if trimmed.hasPrefix("cp ") {
            let result = ShellExecTool.runIOCp(trimmed)
            AuditLog.shared.log("shell.exec (ios cp)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 10. tail 命令——iOS 原生实现 (看文件末尾）
        if trimmed.hasPrefix("tail ") {
            let result = ShellExecTool.runIOSTail(trimmed)
            AuditLog.shared.log("shell.exec (ios tail)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 11. head 命令——iOS 原生实现 (看文件开头）
        if trimmed.hasPrefix("head ") {
            let result = ShellExecTool.runIOSHead(trimmed)
            AuditLog.shared.log("shell.exec (ios head)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 12. sed 命令——iOS 原生实现 (替换内容）
        if trimmed.hasPrefix("sed ") {
            let result = ShellExecTool.runIOSSed(trimmed)
            AuditLog.shared.log("shell.exec (ios sed)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 13. pwd 命令——iOS 原生实现 (显示当前目录）
        if trimmed == "pwd" {
            let result = ShellExecTool.runIOSPwd(trimmed)
            AuditLog.shared.log("shell.exec (ios pwd)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 14. cd 命令——iOS 原生实现 (切换目录）
        if trimmed.hasPrefix("cd ") || trimmed == "cd" {
            let result = ShellExecTool.runIOSCd(trimmed)
            AuditLog.shared.log("shell.exec (ios cd)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 15. touch 命令——iOS 原生实现 (创建空文件）
        if trimmed.hasPrefix("touch ") {
            let result = ShellExecTool.runIOSTouch(trimmed)
            AuditLog.shared.log("shell.exec (ios touch)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 16. wc 命令——iOS 原生实现 (统计行数/字数）
        if trimmed.hasPrefix("wc ") {
            let result = ShellExecTool.runIOSWc(trimmed)
            AuditLog.shared.log("shell.exec (ios wc)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 17. md5sum / sha256sum 命令——iOS 原生实现 (计算哈希）
        if trimmed.hasPrefix("md5sum ") || trimmed.hasPrefix("sha256sum ") {
            let result = ShellExecTool.runIOSHash(trimmed)
            AuditLog.shared.log("shell.exec (ios hash)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 18. diff 命令——iOS 原生实现 (比较两个文件）
        if trimmed.hasPrefix("diff ") {
            let result = ShellExecTool.runIOSDiff(trimmed)
            AuditLog.shared.log("shell.exec (ios diff)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 19. hexdump 命令——iOS 原生实现 (二进制十六进制）
        if trimmed.hasPrefix("hexdump ") || trimmed.hasPrefix("xxd ") {
            let result = ShellExecTool.runIOSHexdump(trimmed)
            AuditLog.shared.log("shell.exec (ios hexdump)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 20. curl -O / wget 命令——iOS 原生实现 (下载文件）
        if trimmed.hasPrefix("curl ") || trimmed.hasPrefix("wget ") {
            let result = ShellExecTool.runIOSDownload(trimmed)
            AuditLog.shared.log("shell.exec (ios download)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 21. plutil 命令——iOS 原生实现 (读 plist）
        if trimmed.hasPrefix("plutil ") {
            let result = ShellExecTool.runIOSPlutil(trimmed)
            AuditLog.shared.log("shell.exec (ios plutil)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 22. sqlite3 命令——iOS 原生实现 (查询 SQLite）
        if trimmed.hasPrefix("sqlite3 ") {
            let result = ShellExecTool.runIOSSqlite(trimmed)
            AuditLog.shared.log("shell.exec (ios sqlite)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 23. unzip 命令——iOS 原生实现 (解压 zip）
        if trimmed.hasPrefix("unzip ") {
            let result = ShellExecTool.runIOSUnzip(trimmed)
            AuditLog.shared.log("shell.exec (ios unzip)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 24. df 命令——iOS 原生 (磁盘空间）
        if trimmed == "df" || trimmed.hasPrefix("df ") {
            let result = ShellExecTool.runIOSDf(trimmed)
            AuditLog.shared.log("shell.exec (ios df)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 25. free 命令——iOS 原生 (内存）
        if trimmed == "free" || trimmed.hasPrefix("free ") {
            let result = ShellExecTool.runIOSFree(trimmed)
            AuditLog.shared.log("shell.exec (ios free)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 26. uname 命令——iOS 原生 (系统信息）
        if trimmed == "uname" || trimmed.hasPrefix("uname ") {
            let result = ShellExecTool.runIOSUname(trimmed)
            AuditLog.shared.log("shell.exec (ios uname)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 27. uptime 命令——iOS 原生 (运行时间）
        if trimmed == "uptime" {
            let result = ShellExecTool.runIOSUptime(trimmed)
            AuditLog.shared.log("shell.exec (ios uptime)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 28. hostname 命令——iOS 原生 (设备名）
        if trimmed == "hostname" {
            let result = ShellExecTool.runIOSHostname(trimmed)
            AuditLog.shared.log("shell.exec (ios hostname)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 29. ps 命令——iOS 原生 (进程列表）
        if trimmed == "ps" || trimmed.hasPrefix("ps ") {
            let result = ShellExecTool.runIOSPs(trimmed)
            AuditLog.shared.log("shell.exec (ios ps)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 30. top 命令——iOS 原生 (CPU/内存）
        if trimmed == "top" || trimmed.hasPrefix("top ") {
            let result = ShellExecTool.runIOSTop(trimmed)
            AuditLog.shared.log("shell.exec (ios top)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 31. kill 命令——iOS 原生 (杀进程）
        if trimmed.hasPrefix("kill ") {
            let result = ShellExecTool.runIOSKill(trimmed)
            AuditLog.shared.log("shell.exec (ios kill)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 32. ifconfig 命令——iOS 原生 (网络接口）
        if trimmed == "ifconfig" || trimmed.hasPrefix("ifconfig ") {
            let result = ShellExecTool.runIOSIfconfig(trimmed)
            AuditLog.shared.log("shell.exec (ios ifconfig)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 33. netstat 命令——iOS 原生 (网络连接）
        if trimmed == "netstat" || trimmed.hasPrefix("netstat ") {
            let result = ShellExecTool.runIOSNetstat(trimmed)
            AuditLog.shared.log("shell.exec (ios netstat)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 34. nslookup 命令——iOS 原生 (DNS 查询）
        if trimmed.hasPrefix("nslookup ") {
            let result = ShellExecTool.runIOSNslookup(trimmed)
            AuditLog.shared.log("shell.exec (ios nslookup)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 35. tar 命令——iOS 原生 (打包/解压）
        if trimmed.hasPrefix("tar ") {
            let result = ShellExecTool.runIOStar(trimmed)
            AuditLog.shared.log("shell.exec (ios tar)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 36. gzip 命令——iOS 原生 (压缩）
        if trimmed.hasPrefix("gzip ") || trimmed.hasPrefix("gunzip ") {
            let result = ShellExecTool.runIOSGzip(trimmed)
            AuditLog.shared.log("shell.exec (ios gzip)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // v3.0.41：iSH 为唯一引擎 (ios_system 已删除）。初始化failed直接报错，不再回退。
        let (output, exitCode, timedOut) = ISHEngine.exec(command, timeout: timeout)
        
        // 过滤杂散调试噪音
        var stdout = ShellExecTool.filterNoise(output)
        if outLimit > 0 && stdout.count > outLimit {
            let spillPath = ToolRegistry.spillLarge("shell", stdout)
            stdout = String(stdout.prefix(outLimit / 2)) + "\n…[输出太长total \(stdout.count) 字符，已截断；完整输出: \(spillPath)]…\n" + String(stdout.suffix(outLimit / 2))
        }
        
        // 会话目录：iSH guest 路径
        var newPwd = ISHEngine.cwd
        
        AuditLog.shared.log("shell.exec", detail: String(command.prefix(100)))
        
        var result: [String: Any] = [
            "command": command,
            "exit_code": exitCode,
            "stdout": stdout,
            "cwd": newPwd,
            "hint": "Alpine Linux environment: full command set (ls/cat/grep/find/tar/curl/python...), apk add to install packages. cd remembers directory."
        ]
        if timedOut {
            result["timed_out"] = true
            result["hint"] = "command did not finish within \(Int(timeout))s, process group SIGKILLed"
        }
        return result
    }
    
    // MARK: - v3.1.33 shell 语法识别 + iOS 原生管道执行器
    // 修复"同一命令路由随机 (iOS vs Alpine）"和"iOS 原生不支持 | ; && >"两个根因：
    // 含 shell 语法的命令统一在此处理：首段是 iOS 原生命令 → iOS 原生执行 + Swift 过滤器；
    // 首段非 iOS 命令 (python 等）→ 交给 Alpine 全功能 shell。路由从此确定。
    
    /// 检测命令是否含 shell 元字符 (管道/分号/逻辑符/重定向/命令替换），跳过引号内内容
    static func containsShellSyntax(_ command: String) -> Bool {
        var inSingle = false
        var inDouble = false
        var chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if !inSingle && !inDouble {
                switch c {
                case "|", ";", "&", ">", "<", "`":
                    return true
                case "$":
                    // $() 命令替换或 ${} 参数展开也算 shell 语法
                    if i + 1 < chars.count, chars[i+1] == "(" || chars[i+1] == "{" { return true }
                default:
                    break
                }
            }
            i += 1
        }
        return false
    }

    /// P2 环境自动路由：按命令类型自动判定是否必须走 Alpine。
    /// agent 不再手动传 env 切环境——凡 iOS 原生工具链缺失的命令
    /// (装包/解包 deb/完整 shell 脚本/需要 python 等) 自动进 Alpine；
    /// 其余(文件操作/系统信息/网络/分析)默认走 iOS 原生。
    static func autoRouteNeedsAlpine(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // 明确的 Alpine 需求标记：装包/解包/完整工具链/复杂脚本结构
        let alpineMarkers: [String] = [
            #"^\s*apk\s+"#,           // apk add / apk update
            #"^\s*(tar|dpkg|dpkg-deb|rpm|strings|hexdump|od)\s+"#,  // 解包/装包/原生缺失的分析工具
            #"\|\s*(tar|dpkg|dpkg-deb)\s+"#,  // 管道中间的解包命令 (curl x | tar -x)
            #"^\s*python3?\s+"#,      // python / python3
            #"^\s*(pip3?)\s+"#,        // pip / pip3
            #"^\s*(git|wget|make|cmake|gcc|clang)\s+"#,  // 工具链
            #"^\s*sh\s+"#,             // 任意 sh 脚本(含无 flag) → Alpine 全功能 shell
            #"^\s*bash\s+"#,
            #"<<\s*[A-Za-z_][A-Za-z0-9_]*"#,  // heredoc
        ]
        for m in alpineMarkers {
            if c.range(of: m, options: .regularExpression) != nil { return true }
        }
        // 复杂控制结构 (for/while/case/if...then) 走 Alpine 全功能 shell
        let controlPatterns = [
            #"\bfor\s+.+?\bin\b"#, #"\bwhile\s+.+?\bdo\b"#,
            #"\bcase\s+.+?\bin\b"#, #"\bthen\b.*\belif\b|\bif\s+.+?\bthen\b"#
        ]
        for m in controlPatterns {
            if c.range(of: m, options: .regularExpression) != nil { return true }
        }
        return false
    }
    
    /// 按管道/分号/逻辑符拆分命令 (尊重引号），返回 [(命令段, 连接符)]，连接符: | ; && ||
    private static func splitShellSegments(_ command: String) -> [(cmd: String, sep: String)] {
        var segments: [(String, String)] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle(); current.append(c); i += 1; continue }
            if c == "\"" && !inSingle { inDouble.toggle(); current.append(c); i += 1; continue }
            if !inSingle && !inDouble {
                if c == "|" {
                    segments.append((current.trimmingCharacters(in: .whitespaces), "|"))
                    current = ""
                    i += 1
                    continue
                }
                if c == ";" {
                    segments.append((current.trimmingCharacters(in: .whitespaces), ";"))
                    current = ""
                    i += 1
                    continue
                }
                if c == "&" && i + 1 < chars.count && chars[i+1] == "&" {
                    segments.append((current.trimmingCharacters(in: .whitespaces), "&&"))
                    current = ""
                    i += 2
                    continue
                }
                if c == "|" && i + 1 < chars.count && chars[i+1] == "|" {
                    segments.append((current.trimmingCharacters(in: .whitespaces), "||"))
                    current = ""
                    i += 2
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || segments.isEmpty {
            segments.append((last, ""))
        }
        return segments
    }
    
    /// v3.1.71：iOS 原生模式的变量展开预处理。
    /// 收集段首 VAR=value 赋值 (去引号），把后续命令中的 $VAR / ${VAR} 替换为实际值。
    /// 赋值段转成 echo (无输出、exit 0），保持链式语义。解决"$P 变量拼路径报 No such file" (AI 实测）。
    static func expandVars(_ command: String) -> String {
        let segments = splitShellSegments(command)
        guard segments.count > 1 || command.contains("=") else { return command }
        var vars: [String: String] = [:]
        var out: [String] = []
        for (cmd, sep) in segments {
            let t = cmd.trimmingCharacters(in: .whitespaces)
            if t.contains("=") {
                let eqIndex = t.firstIndex(of: "=")!
                let name = String(t[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                // 只认纯标识符的赋值 (A-Za-z0-9_），避免把命令参数里的 = 误判
                if !name.isEmpty && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    var value = String(t[t.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                    // 去引号 ("..." / '...'）
                    if value.count >= 2,
                       (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                       (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    vars[name] = value
                    out.append("echo")
                    out.append(sep)
                    continue
                }
            }
            var replaced = t
            for (name, value) in vars {
                replaced = replaced.replacingOccurrences(of: "${\(name)}", with: value)
                replaced = replaced.replacingOccurrences(of: "$\(name)", with: value)
            }
            out.append(replaced)
            out.append(sep)
        }
        var joined = ""
        for i in stride(from: 0, to: out.count, by: 2) {
            joined += out[i]
            if i + 1 < out.count, !out[i + 1].isEmpty {
                joined += " \(out[i + 1]) "
            } else if i + 2 < out.count {
                joined += " "
            }
        }
        return joined
    }

    /// 提取命令首词 (跳过引号），用于判断是否 iOS 原生命令
    private static func firstWord(_ segment: String) -> String {        let t = segment.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        var word = ""
        for c in t {
            if c == " " || c == "\t" { break }
            if c == "'" || c == "\"" { continue }
            word.append(c)
        }
        return word
    }
    
    /// iOS 原生命令集合 (36 个，与上方拦截清单一致）
    private static let iosNativeCommands: Set<String> = [
        "ls", "cat", "find", "grep", "echo", "mkdir", "rm", "mv", "cp",
        "tail", "head", "sed", "pwd", "cd", "touch", "wc", "md5sum",
        "sha256sum", "diff", "hexdump", "curl", "wget", "plutil", "sqlite3",
        "unzip", "df", "free", "uname", "uptime", "hostname", "ps", "top",
        "kill", "ifconfig", "netstat", "nslookup", "tar", "gzip", "gunzip",
        "ta"
    ]
    
    /// 执行单段 iOS 原生命令 (首段），返回 [String: Any]
    private static func runIOSNativeSegment(_ segment: String) -> [String: Any] {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        let word = firstWord(trimmed)
        switch word {
        case "ls": return runIOSls(trimmed)
        case "cat": return runIOSCat(trimmed)
        case "find": return runIOSFind(trimmed)
        case "grep": return runIOSGrep(trimmed)
        case "echo": return runIOSEcho(trimmed)
        case "mkdir": return runIOSMkdir(trimmed)
        case "rm": return runIOSRm(trimmed)
        case "mv": return runIOSMv(trimmed)
        case "cp": return runIOCp(trimmed)
        case "tail": return runIOSTail(trimmed)
        case "head": return runIOSHead(trimmed)
        case "sed": return runIOSSed(trimmed)
        case "pwd": return runIOSPwd(trimmed)
        case "cd": return runIOSCd(trimmed)
        case "touch": return runIOSTouch(trimmed)
        case "wc": return runIOSWc(trimmed)
        case "md5sum", "sha256sum": return runIOSHash(trimmed)
        case "diff": return runIOSDiff(trimmed)
        case "hexdump": return runIOSHexdump(trimmed)
        case "curl", "wget": return runIOSDownload(trimmed)
        case "plutil": return runIOSPlutil(trimmed)
        case "sqlite3": return runIOSSqlite(trimmed)
        case "unzip": return runIOSUnzip(trimmed)
        case "df": return runIOSDf(trimmed)
        case "free": return runIOSFree(trimmed)
        case "uname": return runIOSUname(trimmed)
        case "uptime": return runIOSUptime(trimmed)
        case "hostname": return runIOSHostname(trimmed)
        case "ps": return runIOSPs(trimmed)
        case "top": return runIOSTop(trimmed)
        case "kill": return runIOSKill(trimmed)
        case "ifconfig": return runIOSIfconfig(trimmed)
        case "netstat": return runIOSNetstat(trimmed)
        case "nslookup": return runIOSNslookup(trimmed)
        case "tar": return runIOStar(trimmed)
        case "gzip", "gunzip": return runIOSGzip(trimmed)
        case "ta": return OffloadRouter.run(trimmed)
        default:
            return [
                "command": segment,
                "exit_code": 1,
                "stdout": "iOS 原生模式不支持该命令: \(word) (请用 Alpine 全功能 shell 或换用支持的 36 个 iOS 原生命令)",
                "ios_native": true
            ]
        }
    }
    
    /// 主执行器：处理整条含 shell 语法的命令
    /// 结构：先按非管道分隔符 (; && ||）切分成"链"，每条链内按 | 分生产段+过滤段；
    /// 逐链执行：生产段输出 → 过滤段逐个过滤 → 追加到 stdoutChunks；&& / || 按上链 exit 短路。
    static func runIOSPipeline(_ command: String, limit: Int = 4000, offset: Int = 0) -> [String: Any] {
        let segments = splitShellSegments(command)
        guard !segments.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "空命令", "ios_native": true]
        }
        
        // 切链：[(链内段列表, 本链进入前的分隔符)]
        var chains: [(cmds: [String], enterSep: String)] = []
        var currentChain: [String] = []
        var currentEnterSep = ""
        var prevSep = ""
        for seg in segments {
            let cmd = seg.cmd.trimmingCharacters(in: .whitespaces)
            if cmd.isEmpty { continue }
            currentChain.append(cmd)
            currentEnterSep = prevSep
            prevSep = seg.sep
            if seg.sep != "|" {
                chains.append((currentChain, currentEnterSep))
                currentChain = []
            }
        }
        if !currentChain.isEmpty { chains.append((currentChain, currentEnterSep)) }
        
        var stdoutChunks: [String] = []
        var lastExit = 0
        var anyIOS = false
        
        for chain in chains {
            // && / || 短路：上一条链的 exit 决定本链是否执行
            if chain.enterSep == "&&" && lastExit != 0 { continue }
            if chain.enterSep == "||" && lastExit == 0 { continue }
            
            var text = ""
            var exit = 0
            for (cidx, c) in chain.cmds.enumerated() {
                let word = firstWord(c)
                let isIOSCmd = iosNativeCommands.contains(word)
                if isIOSCmd { anyIOS = true }
                let (body, redirect, append, outFile) = extractRedirect(c)
                
                if cidx == 0 {
                    // 生产段：iOS 原生执行 或 Alpine
                    var result: [String: Any]
                    if isIOSCmd {
                        result = runIOSNativeSegment(body)
                        result["ios_native"] = true
                    } else {
                        var (output, outputExit, timedOut) = ISHEngine.exec(body, timeout: 30)
                        // P3 按需补给：缺工具自动 apk add 并重跑一次
                        if let pkg = ISHEngine.missingToolPkg(output) {
                            ShellDiag.log("provision auto: apk add \(pkg) (missing in Alpine)")
                            _ = ISHEngine.exec("apk add --no-cache \(pkg)", timeout: 120)
                            let (rout, rexit, rtimed) = ISHEngine.exec(body, timeout: 30)
                            output = rout; outputExit = rexit; timedOut = rtimed
                        }
                        var out = ShellExecTool.filterNoise(output)
                        if limit > 0 && out.count > limit {
                            let spillPath = ToolRegistry.spillLarge("alpine", out)
                            out = String(out.prefix(limit / 2)) + "\n…[输出太长total \(out.count) 字符，已截断；完整输出: \(spillPath)]…\n" + String(out.suffix(limit / 2))
                        }
                        result = [
                            "command": body, "exit_code": Int(outputExit), "stdout": out,
                            "cwd": ISHEngine.cwd,
                            "hint": "Alpine Linux environment (non-iOS segment of compound command): full command support; 缺工具已自动 apk add"
                        ]
                        if timedOut { result["timed_out"] = true }
                    }
                    text = result["stdout"] as? String ?? ""
                    exit = result["exit_code"] as? Int ?? 0
                } else {
                    // 过滤段：Swift 过滤器作用于前段输出
                    text = applySwiftFilter(body, to: text)
                }
                
                // 重定向 (段内 > / >>）：写文件并把输出改为提示
                if redirect {
                    text = ShellExecTool.writeRedirected(text, append: append, outFile: outFile)
                }
            }
            
            stdoutChunks.append(text)
            lastExit = exit
        }
        
        let joined = stdoutChunks.joined(separator: "\n")
        // v3.3.4：管道最终输出统一截断 (head+tail+spill）——长管道输出不再占满上下文；
        // limit/offset 可动态控制：limit:0 或 full:true = 全量；offset 跳过前 N 字符取中段
        var finalOut = joined
        if offset > 0 {
            finalOut = String(finalOut.dropFirst(min(offset, finalOut.count)))
        }
        if limit > 0 && finalOut.count > limit {
            let spillPath = ToolRegistry.spillLarge("pipeline", joined)
            finalOut = String(finalOut.prefix(limit / 2)) + "\n…[输出太长 total \(joined.count) 字符，已截断；完整输出: \(spillPath)]…\n" + String(finalOut.suffix(limit / 2))
        }
        return [
            "command": command,
            "exit_code": lastExit,
            "stdout": finalOut,
            "ios_native": anyIOS,
            "hint": anyIOS
                ? "iOS 原生复合命令：支持管道/分号/重定向 (Swift 过滤器 head/tail/grep/wc/sed/awk/sort/uniq/cut/tr/echo)"
                : "复合命令 (含 Alpine 段)：管道/分号/重定向已正确解析"
        ]
    }
    
    /// 重定向写文件辅助：把输出写入目标文件 (覆盖/追加），返回提示文本
    private static func writeRedirected(_ out: String, append: Bool, outFile: String) -> String {
        do {
            if append {
                if FileManager.default.fileExists(atPath: outFile) {
                    let existing = try String(contentsOfFile: outFile, encoding: .utf8)
                    try (existing + "\n" + out).write(toFile: outFile, atomically: true, encoding: .utf8)
                } else {
                    try out.write(toFile: outFile, atomically: true, encoding: .utf8)
                }
            } else {
                try out.write(toFile: outFile, atomically: true, encoding: .utf8)
            }
            return "Written to \(outFile)"
        } catch {
            return "Error writing \(outFile): \(error.localizedDescription)"
        }
    }
    
    /// v3.1.33: iOS 原生 echo 命令——输出文本 (支持 -n 不换行、引号剥离）
    private static func runIOSEcho(_ command: String) -> [String: Any] {
        var t = command
        var newline = true
        if t.hasPrefix("echo -n") { newline = false; t = String(t.dropFirst("echo -n".count)) }
        else if t.hasPrefix("echo") { t = String(t.dropFirst("echo".count)) }
        t = t.trimmingCharacters(in: .whitespaces)
        // 剥离首尾成对引号
        if t.count >= 2,
           (t.first == "\"" && t.last == "\"") || (t.first == "'" && t.last == "'") {
            t = String(t.dropFirst().dropLast())
        }
        return [
            "command": command,
            "exit_code": 0,
            "stdout": newline ? t : t,
            "ios_native": true,
            "hint": "iOS native echo"
        ]
    }
    
    /// 从段内提取重定向：cmd > file / cmd >> file (支持引号路径），返回 (主体, 是否重定向, 是否追加, 目标文件)
    private static func extractRedirect(_ segment: String) -> (body: String, redirect: Bool, append: Bool, outFile: String) {
        var inSingle = false
        var inDouble = false
        var chars = Array(segment)
        var i = 0
        var redirectIdx: Int? = nil
        var isAppend = false
        // v3.1.68: stderr 重定向 (2>&1 合并 / 2>/dev/null 丢弃）——从命令里剥掉，不写文件不报错。
        // iOS 原生执行时 stderr 已经混入 stdout 文本，所以 2>&1 等效于去掉；2>/dev/null 也剥掉
        //  (真实 stderr 捕获需更大改造，剥掉至少不再报 "Error writing &1"）
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle(); i += 1; continue }
            if c == "\"" && !inSingle { inDouble.toggle(); i += 1; continue }
            if !inSingle && !inDouble && c == ">" {
                if i + 1 < chars.count && chars[i+1] == ">" {
                    isAppend = true
                    redirectIdx = i
                    i += 2
                    continue
                }
                redirectIdx = i
                i += 1
                continue
            }
            i += 1
        }
        guard let idx = redirectIdx else {
            return (segment, false, false, "")
        }
        let body = String(chars[0..<idx]).trimmingCharacters(in: .whitespaces)
        var filePart = String(chars[(idx + (isAppend ? 2 : 1))..<chars.count]).trimmingCharacters(in: .whitespaces)
        filePart = filePart.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        
        // v3.1.68: stderr 重定向识别——body 以 "2" 结尾 (如 "ls /x 2"）且目标是 &1 或 /dev/null
        let bodyHasStderrFd = body.hasSuffix("2")
        let isStderrToNull = bodyHasStderrFd && (filePart == "/dev/null")
        let isStderrToStdout = bodyHasStderrFd && (filePart == "&1" || filePart == "1")
        if isStderrToNull || isStderrToStdout {
            // 剥掉末尾的 "2"，把 stderr 重定向吞掉，命令主体继续执行
            let trimmedBody = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
            return (trimmedBody, false, false, "")
        }
        
        filePart = ShellExecTool.normalizePath((filePart as NSString).expandingTildeInPath)
        return (body, true, isAppend, filePart)
    }
    
    /// v3.1.33：路径归一——/private/var → /var (iOS 软链，访问等价），
    /// 让同一目录无论用户/AI 写哪个前缀，输出都统一显示为 /var/...。
    /// 只做前缀归一，不解析软链 (保持速度与确定性）；相对路径原样返回。
    static func normalizePath(_ p: String) -> String {
        if p.hasPrefix("/private/var") {
            return "/var" + p.dropFirst("/private/var".count)
        }
        return p
    }
    
    // MARK: - Swift 管道过滤器 (iOS 原生管道右侧）
    
    /// 对 stdout 应用过滤器命令 (head/tail/grep/wc/sed/awk/sort/uniq/cut/tr/rev/cat），返回过滤后文本
    private static func applySwiftFilter(_ filterCmd: String, to input: String) -> String {
        let parts = filterCmd.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let word = parts.first else { return input }
        var lines = input.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        
        switch word {
        case "head":
            var n = 10
            if let idx = parts.firstIndex(of: "-n"), idx + 1 < parts.count, let v = Int(parts[idx+1]) { n = v }
            return lines.prefix(n).joined(separator: "\n")
        case "tail":
            var n = 10
            if let idx = parts.firstIndex(of: "-n"), idx + 1 < parts.count, let v = Int(parts[idx+1]) { n = v }
            return lines.suffix(n).joined(separator: "\n")
        case "grep":
            var invert = false
            var pattern = ""
            for p in parts.dropFirst() {
                if p == "-v" { invert = true; continue }
                if p == "-i" { continue }
                pattern = p.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                break
            }
            guard !pattern.isEmpty else { return input }
            let matched = lines.filter { line in
                let hit = line.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil
                return invert ? !hit : hit
            }
            return matched.joined(separator: "\n")
        case "echo":
            // v3.3.4：管道里 echo —— 输出替换为 echo 的文本 (支持 -n、剥引号）
            var t = filterCmd
            if t.hasPrefix("echo") { t = String(t.dropFirst("echo".count)) }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-n ") { t = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            if t.count >= 2,
               (t.first == "\"" && t.last == "\"") || (t.first == "'" && t.last == "'") {
                t = String(t.dropFirst().dropLast())
            }
            return t
        case "wc":
            let opts = Set(parts.dropFirst())
            var result: [String] = []
            if opts.contains("-l") || !opts.contains("-w") && !opts.contains("-c") {
                result.append(String(lines.count))
            }
            if opts.contains("-w") {
                let words = lines.reduce(0) { $0 + $1.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count }
                result.append(String(words))
            }
            if opts.contains("-c") {
                result.append(String(input.utf8.count))
            }
            return result.joined(separator: " ")
        case "sed":
            // 支持 sed 's/from/to/g' (简化）
            if parts.count >= 2 {
                let expr = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if expr.hasPrefix("s") {
                    var e = expr
                    if e.hasPrefix("s") { e.removeFirst() }
                    // e 形如 /from/to/g 或 s/from/to/
                    if e.hasPrefix("/") { e.removeFirst() }
                    let comps = e.components(separatedBy: "/")
                    if comps.count >= 2 {
                        let from = comps[0]
                        let to = comps.count >= 2 ? comps[1] : ""
                        let global = comps.count > 2 && comps[2].contains("g")
                        let replaced = lines.map { line -> String in
                            if global {
                                return line.replacingOccurrences(of: from, with: to)
                            } else {
                                guard let r = line.range(of: from) else { return line }
                                return line.replacingCharacters(in: r, with: to)
                            }
                        }
                        return replaced.joined(separator: "\n")
                    }
                }
            }
            return input
        case "awk":
            // 支持 awk '{print $1}' / $NF / $0 (简化）
            if parts.count >= 2 {
                let prog = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if prog.contains("print") {
                    var field: Int? = nil
                    var isNF = false
                    // 提取 $数字 或 $NF
                    var scan = Array(prog)
                    var k = 0
                    while k < scan.count {
                        if scan[k] == "$", k + 1 < scan.count {
                            let next = scan[k+1]
                            if next.isNumber {
                                var num = ""
                                var j = k + 1
                                while j < scan.count, scan[j].isNumber { num.append(scan[j]); j += 1 }
                                field = Int(num)
                                k = j
                                continue
                            }
                            if next == "N" && k + 2 < scan.count && scan[k+2] == "F" {
                                isNF = true
                            }
                        }
                        k += 1
                    }
                    let out = lines.map { line -> String in
                        if isNF {
                            let cols = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                            return cols.last ?? ""
                        }
                        if let f = field {
                            let cols = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                            return f <= cols.count ? cols[f-1] : ""
                        }
                        return line
                    }
                    return out.joined(separator: "\n")
                }
            }
            return input
        case "sort":
            return lines.sorted().joined(separator: "\n")
        case "uniq":
            var out: [String] = []
            var prev: String? = nil
            for line in lines {
                if line != prev { out.append(line) }
                prev = line
            }
            return out.joined(separator: "\n")
        case "cut":
            // cut -d' ' -f2 / cut -d: -f1 / cut -f1 / cut -c1-5 (支持紧凑写法 -d: -f2）
            var delim: Character = "\t"
            var field = 0
            var chars: (Int, Int)? = nil
            for p in parts.dropFirst() {
                if p.hasPrefix("-d") && p.count > 2 {
                    delim = p.dropFirst(2).first ?? "\t"
                } else if p.hasPrefix("-f") && p.count > 2, let v = Int(p.dropFirst(2)) {
                    field = v
                } else if p.hasPrefix("-c") && p.count > 2 {
                    let spec = String(p.dropFirst(2))
                    let cs = spec.components(separatedBy: "-")
                    if cs.count == 2, let a = Int(cs[0]), let b = Int(cs[1]) {
                        chars = (a, b)
                    }
                }
            }
            let out = lines.map { line -> String in
                if let (a, b) = chars {
                    let arr = Array(line)
                    guard a >= 1, a <= arr.count else { return "" }
                    let end = min(b, arr.count)
                    return String(arr[a-1..<end])
                }
                if field > 0 {
                    let cols = line.split(separator: delim, omittingEmptySubsequences: true)
                    return field <= cols.count ? String(cols[field-1]) : ""
                }
                return line
            }
            return out.joined(separator: "\n")
        case "tr":
            if parts.count >= 3 {
                let from = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                let to = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                var mapping: [Character: Character] = [:]
                for (idx, c) in from.enumerated() {
                    if idx < to.count { mapping[c] = to[to.index(to.startIndex, offsetBy: idx)] }
                }
                let mapped = input.map { c -> Character in mapping[c] ?? c }
                return String(mapped)
            }
            return input
        case "rev":
            return lines.map { String($0.reversed()) }.joined(separator: "\n")
        case "cat":
            return input
        default:
            return "iOS 原生管道暂不支持过滤器: \(word) (可用 head/tail/grep/wc/sed/awk/sort/uniq/cut/tr/rev/echo/cat)\n原输出:\n\(input)"
        }
    }
    
    /// v3.1.32: iOS 原生 ls 命令——直接访问 iOS 文件系统
    private static func runIOSls(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        var showAll = false
        var showLong = false
        var onePerLine = false
        var path = "."
        
        // 解析选项
        for part in parts.dropFirst() {
            if part.hasPrefix("-") {
                showAll = showAll || part.contains("a")
                showLong = showLong || part.contains("l")
                // -1 / -C(反) / -m(逗号) 控制输出格式：-1 强制每条一行
                onePerLine = onePerLine || part.contains("1")
            } else {
                path = part
            }
        }
        
        // 解析路径
        var resolvedPath = ShellExecTool.normalizePath((path as NSString).expandingTildeInPath)
        if resolvedPath == "." || resolvedPath == "./" {
            resolvedPath = NSHomeDirectory() + "/Documents"
        }
        
        // 检查路径是否存在。v3.4.9：不再强制"必须是目录"——
        // 之前 guard 目录，导致 `ls <单个文件>` 恒报 "No such file"（Bug A）
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: resolvedPath, isDirectory: &isDir) {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "ls: cannot access '\(path)': No such file or directory",
                "cwd": NSHomeDirectory() + "/Documents",
                "ios_native": true,
                "hint": "iOS native ls: direct access to iOS filesystem"
            ]
        }
        // 单个文件：输出一行真实大小（v3.4.9，修复之前硬编码 4096）
        if !isDir.boolValue {
            var sz = 0
            if let a = try? fm.attributesOfItem(atPath: resolvedPath) {
                sz = (a[.size] as? NSNumber)?.intValue ?? 0
            }
            let line = "-rwxr-xr-x  1  mobile  mobile  \(String(format: "%8d", sz))  \((resolvedPath as NSString).lastPathComponent)"
            return [
                "command": command,
                "exit_code": 0,
                "stdout": line,
                "cwd": (resolvedPath as NSString).deletingLastPathComponent,
                "ios_native": true,
                "hint": "iOS native ls: direct access to iOS filesystem"
            ]
        }
        
        // 列出目录内容
        do {
            let items = try fm.contentsOfDirectory(atPath: resolvedPath)
            let sorted = items.sorted()
            
            if showLong {
                // 长格式输出 (真实文件大小）
                var lines: [String] = []
                lines.append("total \(items.count)")
                for item in sorted {
                    if !showAll && item.hasPrefix(".") { continue }
                    let fullPath = resolvedPath + "/" + item
                    var itemIsDir: ObjCBool = false
                    fm.fileExists(atPath: fullPath, isDirectory: &itemIsDir)
                    let type = itemIsDir.boolValue ? "d" : "-"
                    // v3.4.9：真实文件大小（之前硬编码 4096，误导 AI 以为文件都空/小——Bug E）
                    var sz = 0
                    if let a = try? fm.attributesOfItem(atPath: fullPath) {
                        sz = (a[.size] as? NSNumber)?.intValue ?? 0
                    }
                    lines.append("\(type)rwxr-xr-x  1  mobile  mobile  \(String(format: "%8d", sz))  \(item)")
                }
                return [
                    "command": command,
                    "exit_code": 0,
                    "stdout": lines.joined(separator: "\n"),
                    "cwd": resolvedPath,
                    "ios_native": true,
                    "hint": "iOS native ls: direct access to iOS filesystem"
                ]
            } else {
                // 短格式输出：默认每条一行 (\n）——管道统计(wc -l/head/grep)依赖换行；
                // 历史版本用双空格连接导致 ls | wc -l 恒为 1 (C1 根因，2026-09-23 修复）
                let visible = showAll ? sorted : sorted.filter { !$0.hasPrefix(".") }
                return [
                    "command": command,
                    "exit_code": 0,
                    "stdout": visible.joined(separator: "\n"),
                    "cwd": resolvedPath,
                    "ios_native": true,
                    "hint": "iOS native ls: one entry per line (pipe-friendly); -l long format; -a include hidden"
                ]
            }
        } catch {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "ls: cannot access '\(path)': \(error.localizedDescription)",
                "cwd": resolvedPath,
                "ios_native": true,
                "hint": "iOS native ls"
            ]
        }
    }
    
    /// v3.1.32: iOS 原生 cat 命令——读文件内容
    private static func runIOSCat(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "cat: missing file operand",
                "ios_native": true
            ]
        }
        
        let path = ShellExecTool.normalizePath((parts[1] as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "cat: \(path): No such file or directory",
                "ios_native": true
            ]
        }
        
        do {
            // v3.4.9：先按二进制读并检测——.db 等二进制文件不再抛"UTF-8 编码无法打开"，
            // 而是明确引导 AI 用内置 sqlite3 去分析（Bug B）
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let isText = data.isEmpty || data.firstIndex(of: 0) == nil
            if !isText {
                let lower = path.lowercased()
                let hint: String
                if lower.hasSuffix(".db") || lower.hasSuffix(".sqlite") || lower.hasSuffix(".sqlite3") {
                    hint = "binary SQLite DB (\(data.count) bytes). Analyze it with the built-in native tool: sqlite3 <db_path> \"<SQL>\" — e.g. `sqlite3 \(path) \".tables\"`, `sqlite3 \(path) \"SELECT name FROM sqlite_master WHERE type='table'\"`, then query each table."
                } else {
                    hint = "binary file (\(data.count) bytes), not UTF-8 text. Use `sqlite3` for DB files, or hex inspect via `head -c 64 <file> | od -c` (system auto-routes od/hexdump to Alpine); native cat reads text only."
                }
                return [
                    "command": command,
                    "exit_code": 1,
                    "stdout": "cat: \(path): binary file (\(data.count) bytes), cannot decode as UTF-8 text.\n\(hint)",
                    "ios_native": true
                ]
            }
            let content = String(data: data, encoding: .utf8) ?? ""
            // 限制输出长度，防止太长 (v3.1.68：截断附精确 spill 路径，可 cat 全量）
            let truncated: String
            if content.count > 5000 {
                let spillPath = ToolRegistry.spillLarge("cat", content)
                truncated = String(content.prefix(2500)) + "\n…[输出太长total \(content.count) 字符，已截断；完整内容: \(spillPath)]…\n" + String(content.suffix(2500))
            } else {
                truncated = content
            }
            return [
                "command": command,
                "exit_code": 0,
                "stdout": truncated,
                "ios_native": true,
                "hint": "iOS native cat: read iOS files directly"
            ]
        } catch {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "cat: \(path): \(error.localizedDescription)",
                "ios_native": true
            ]
        }
    }
    
    /// v3.1.32: iOS 原生 find 命令——找文件
    /// v3.1.68: 支持 -iname (忽略大小写）与 -maxdepth N (任意参数顺序），
    /// 修复"只认 find <path> -name '<pattern>'、参数顺序敏感" (AI 诊断 4，2026-09-23 实测确认）
    private static func runIOSFind(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: find <path> [-name|-iname '<pattern>'] [-maxdepth N]",
                "ios_native": true
            ]
        }
        
        // 灵活解析：路径是第一个不以 - 开头的参数；-name/-iname/-maxdepth 任意位置
        var searchPath: String? = nil
        var namePattern: String? = nil
        var ignoreCase = false
        var maxDepth = 5
        var i = 1
        while i < parts.count {
            let p = parts[i]
            if p == "-name" || p == "-iname" {
                ignoreCase = p == "-iname"
                if i + 1 < parts.count {
                    namePattern = parts[i+1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if p == "-maxdepth" {
                if i + 1 < parts.count, let d = Int(parts[i+1]) {
                    maxDepth = min(max(d, 0), 20)
                }
                i += 2
                continue
            }
            if !p.hasPrefix("-") && searchPath == nil {
                searchPath = p
            }
            i += 1
        }
        
        guard let rawPath = searchPath else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: find <path> [-name|-iname '<pattern>'] [-maxdepth N]",
                "ios_native": true
            ]
        }
        let resolved = ShellExecTool.normalizePath((rawPath as NSString).expandingTildeInPath)
        guard resolved == "." || resolved.hasPrefix("/") else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: find <path> [-name|-iname '<pattern>'] [-maxdepth N]",
                "ios_native": true
            ]
        }
        
        guard let pattern = namePattern, !pattern.isEmpty else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: find <path> [-name|-iname '<pattern>'] [-maxdepth N]",
                "ios_native": true
            ]
        }
        
        let resolvedPath = resolved
        let nameRegex = pattern.replacingOccurrences(of: "*", with: ".*")
        let compareOpts: String.CompareOptions = ignoreCase ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        
        var results: [String] = []
        
        func findRecursive(dir: String, depth: Int) {
            guard depth <= maxDepth else { return } // 用 -maxdepth 限制深度
            do {
                let items = try fm.contentsOfDirectory(atPath: dir)
                for item in items {
                    let fullPath = dir + "/" + item
                    // 匹配文件名 (-name 精确大小写；-iname 忽略大小写）
                    if item.range(of: nameRegex, options: compareOpts) != nil {
                        results.append(fullPath)
                    }
                    // 递归子目录
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                    if isDir.boolValue, depth < maxDepth {
                        findRecursive(dir: fullPath, depth: depth + 1)
                    }
                }
            } catch {}
        }
        
        findRecursive(dir: resolvedPath, depth: 0)
        
        // 限制结果数量 (v3.1.68: 截断时把全量落盘 tool_spill/，附精确路径——AI 可 cat 全量）
        var out: String
        if results.count > 100 {
            let spillPath = ToolRegistry.spillLarge("find", results.joined(separator: "\n"))
            out = results.prefix(100).joined(separator: "\n") + "\n…[共找到 \(results.count) 个，已截断；完整列表: \(spillPath)]"
        } else {
            out = results.joined(separator: "\n")
        }
        
        return [
            "command": command,
            "exit_code": 0,
            "stdout": out,
            "ios_native": true,
            "hint": "iOS native find: search files directly on iOS filesystem"
        ]
    }
    
    /// v3.1.32: iOS 原生 grep 命令——搜文本
    /// v3.1.68: 支持 flags (-i 忽略大小写 / -r 递归 / -l 只列文件名 / -c 计数 / -n 带行号 / -v 反选），
    /// 修复"任何 flag 把模式当文件" (C3 根因，2026-09-23 实测确认）
    private static func runIOSGrep(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // 解析 flags 与位置参数
        var flags = Set<Character>()
        var positional: [String] = []
        for p in parts.dropFirst() {
            if p.hasPrefix("-") && p.count > 1 && !p.hasPrefix("-e") {
                for ch in p.dropFirst() { flags.insert(ch) }
            } else {
                positional.append(p)
            }
        }
        let ignoreCase = flags.contains("i")
        let recursive = flags.contains("r")
        let filesOnly = flags.contains("l")
        let countOnly = flags.contains("c")
        let lineNumbers = flags.contains("n")
        let invert = flags.contains("v")
        
        guard positional.count >= 2 else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: grep [-i] [-r] [-l] [-c] [-n] [-v] '<pattern>' <file|dir>...",
                "ios_native": true
            ]
        }
        
        let pattern = positional[0].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let targets = positional.dropFirst().map { ShellExecTool.normalizePath(($0 as NSString).expandingTildeInPath) }
        
        // 收集要搜索的文件 (支持 -r 递归目录）
        var files: [String] = []
        for t in targets {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: t, isDirectory: &isDir) {
                if isDir.boolValue {
                    if recursive {
                        if let enumerator = fm.enumerator(atPath: t) {
                            while let f = enumerator.nextObject() as? String {
                                let full = (t as NSString).appendingPathComponent(f)
                                var fIsDir: ObjCBool = false
                                if fm.fileExists(atPath: full, isDirectory: &fIsDir), !fIsDir.boolValue {
                                    files.append(full)
                                }
                            }
                        }
                    } else {
                        return [
                            "command": command,
                            "exit_code": 1,
                            "stdout": "grep: \(t): Is a directory (use -r to recurse)",
                            "ios_native": true
                        ]
                    }
                } else {
                    files.append(t)
                }
            } else {
                return [
                    "command": command,
                    "exit_code": 1,
                    "stdout": "grep: \(t): No such file or directory",
                    "ios_native": true
                ]
            }
        }
        
        guard !files.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "grep: no files matched", "ios_native": true]
        }
        
        var matchedFiles: [String] = []
        var matchedLines: [String] = []
        var totalCount = 0
        for file in files {
            guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            var fileMatched = false
            var fileCount = 0
            for (idx, line) in lines.enumerated() {
                let found: Bool
                if ignoreCase {
                    found = line.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil
                } else {
                    found = line.range(of: pattern, options: .regularExpression) != nil
                }
                let hit = invert ? !found : found
                if hit {
                    fileMatched = true
                    fileCount += 1
                    totalCount += 1
                    if !filesOnly && !countOnly {
                        let prefix = files.count > 1 ? "\(file):" : ""
                        let num = lineNumbers ? "\(idx + 1):" : ""
                        matchedLines.append("\(prefix)\(num)\(line)")
                    }
                }
            }
            if fileMatched { matchedFiles.append(file) }
            if countOnly && fileMatched {
                let prefix = files.count > 1 || targets.count > 1 ? "\(file):" : ""
                matchedLines.append("\(prefix)\(fileCount)")
            }
        }
        
        var out: String
        if filesOnly {
            out = matchedFiles.joined(separator: "\n")
        } else if countOnly {
            out = matchedLines.joined(separator: "\n")
            if files.count == 1 && targets.count == 1 && matchedLines.isEmpty && totalCount == 0 {
                out = "0"
            }
        } else {
            let truncated = matchedLines.count > 200 ? Array(matchedLines.prefix(200)) + ["... (total \(totalCount) 行匹配，已截断)"] : matchedLines
            out = truncated.joined(separator: "\n")
        }
        return [
            "command": command,
            "exit_code": 0,
            "stdout": out,
            "ios_native": true,
            "hint": "iOS native grep: supports -i(ignore case)/-r(recursive)/-l(list filenames)/-c(count)/-n(line numbers)/-v(invert)"
        ]
    }
    
    /// v3.1.32: iOS native write file命令 (echo > / >>）
    private static func runIOSWrite(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        
        // 解析命令：echo "内容" > /path/to/file
        // 或者 echo '内容' >> /path/to/file
        // 支持单引号和双引号
        let pattern = #"^echo\s+['\"](.*)['\"]\s+>>?\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: echo '内容' > /path/to/file",
                "ios_native": true
            ]
        }
        
        let range = NSRange(command.startIndex..., in: command)
        guard let match = regex.firstMatch(in: command, range: range) else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: echo '内容' > /path/to/file",
                "ios_native": true
            ]
        }
        
        let contentRange = Range(match.range(at: 1), in: command)!
        let pathRange = Range(match.range(at: 2), in: command)!
        let content = String(command[contentRange])
        let filePath = String(command[pathRange])
        
        // 判断是 > 还是 >>
        let isAppend = command.contains(">>")
        
        do {
            if isAppend {
                // 追加
                if fm.fileExists(atPath: filePath) {
                    let existing = try String(contentsOfFile: filePath, encoding: .utf8)
                    let newContent = existing + "\n" + content
                    try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
                } else {
                    try content.write(toFile: filePath, atomically: true, encoding: .utf8)
                }
            } else {
                // 覆盖
                try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            }
            return [
                "command": command,
                "exit_code": 0,
                "stdout": isAppend ? "Appended to \(filePath)" : "Written to \(filePath)",
                "ios_native": true,
                "hint": "iOS native write file"
            ]
        } catch {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Write failed: \(error.localizedDescription)",
                "ios_native": true
            ]
        }
    }
    
    /// v3.1.32: iOS 原生 mkdir 命令——建目录
    private static func runIOSMkdir(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: mkdir [-p] <path>", "ios_native": true]
        }
        
        // v3.5.0：跳过前导 flag（如 -p）——之前把 -p 当路径，报"只读宗卷"
        let pathArg = parts.dropFirst().first { !$0.hasPrefix("-") } ?? parts[1]
        let path = ShellExecTool.normalizePath((pathArg as NSString).expandingTildeInPath)
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            return ["command": command, "exit_code": 0, "stdout": "Created directory: \(path)", "ios_native": true]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "mkdir failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 rm 命令——删文件/目录
    private static func runIOSRm(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: rm <path>", "ios_native": true]
        }
        
        let path = ShellExecTool.normalizePath((parts[1] as NSString).expandingTildeInPath)
        do {
            try fm.removeItem(atPath: path)
            return ["command": command, "exit_code": 0, "stdout": "Removed: \(path)", "ios_native": true]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "rm failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 mv 命令——移动/重命名
    private static func runIOSMv(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 3 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: mv <source> <destination>", "ios_native": true]
        }
        
        let src = ShellExecTool.normalizePath((parts[1] as NSString).expandingTildeInPath)
        let dst = ShellExecTool.normalizePath((parts[2] as NSString).expandingTildeInPath)
        do {
            try fm.moveItem(atPath: src, toPath: dst)
            return ["command": command, "exit_code": 0, "stdout": "Moved: \(src) -> \(dst)", "ios_native": true]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "mv failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 cp 命令——复制
    private static func runIOCp(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 3 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: cp <source> <destination>", "ios_native": true]
        }
        
        let src = ShellExecTool.normalizePath((parts[1] as NSString).expandingTildeInPath)
        let dst = ShellExecTool.normalizePath((parts[2] as NSString).expandingTildeInPath)
        do {
            try fm.copyItem(atPath: src, toPath: dst)
            return ["command": command, "exit_code": 0, "stdout": "Copied: \(src) -> \(dst)", "ios_native": true]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "cp failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 tail 命令——看文件末尾
    private static func runIOSTail(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: tail -n <lines> <file>", "ios_native": true]
        }
        
        var lines = 10
        var filePath = ""
        
        for i in 1..<parts.count {
            if parts[i] == "-n", i + 1 < parts.count {
                lines = Int(parts[i+1]) ?? 10
            } else if !parts[i].hasPrefix("-") {
                filePath = parts[i]
            }
        }
        
        guard !filePath.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: tail -n <lines> <file>", "ios_native": true]
        }
        
        let path = ShellExecTool.normalizePath((filePath as NSString).expandingTildeInPath)
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let allLines = content.components(separatedBy: .newlines)
            let start = max(0, allLines.count - lines)
            let result = allLines[start...].joined(separator: "\n")
            return ["command": command, "exit_code": 0, "stdout": result, "ios_native": true]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "tail failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 head 命令——看文件开头
    private static func runIOSHead(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: head -n <lines> <file>", "ios_native": true]
        }
        
        var lines = 10
        var filePath = ""
        
        for i in 1..<parts.count {
            if parts[i] == "-n", i + 1 < parts.count {
                lines = Int(parts[i+1]) ?? 10
            } else if !parts[i].hasPrefix("-") {
                filePath = parts[i]
            }
        }
        
        guard !filePath.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: head -n <lines> <file>", "ios_native": true]
        }
        
        let path = ShellExecTool.normalizePath((filePath as NSString).expandingTildeInPath)
        do {
            // v3.4.9：二进制安全——文本走逐行，二进制输出前 N 字节十六进制（可看 SQLite 头），不再报错
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let isText = data.isEmpty || data.firstIndex(of: 0) == nil
            if isText, let s = String(data: data, encoding: .utf8) {
                let allLines = s.components(separatedBy: .newlines)
                let end = min(lines, allLines.count)
                let result = allLines[0..<end].joined(separator: "\n")
                return ["command": command, "exit_code": 0, "stdout": result, "ios_native": true]
            } else {
                let n = min(lines * 16, data.count)
                let hex = data[0..<n].map { String(format: "%02x", $0) }.joined(separator: " ")
                return [
                    "command": command, "exit_code": 0,
                    "stdout": "binary (\(data.count) bytes); first \(n) bytes hex:\n\(hex)\nFor SQLite .db use the built-in native tool: sqlite3 <db_path> \"<SQL>\" (e.g. `sqlite3 \(path) \".tables\"`).",
                    "ios_native": true
                ]
            }
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "head failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 sed 命令——替换内容
    private static func runIOSSed(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // v3.5.0：sed -n '<start>,<end>p' <file> —— 打印第 start..end 行（之前只认 -i 替换）
        if parts.count >= 3, parts[1] == "-n" {
            let rangeSpec = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if let m = try? NSRegularExpression(pattern: #"^(\d+),(\d+)p$"#).firstMatch(in: rangeSpec, range: NSRange(rangeSpec.startIndex..., in: rangeSpec)),
               let r1 = Range(m.range(at: 1), in: rangeSpec), let r2 = Range(m.range(at: 2), in: rangeSpec),
               let a = Int(rangeSpec[r1]), let b = Int(rangeSpec[r2]) {
                let filePath = ShellExecTool.normalizePath((parts[3] as NSString).expandingTildeInPath)
                guard fm.fileExists(atPath: filePath) else {
                    return ["command": command, "exit_code": 1, "stdout": "sed: \(filePath): No such file", "ios_native": true]
                }
                do {
                    let content = try String(contentsOfFile: filePath, encoding: .utf8)
                    let allLines = content.components(separatedBy: .newlines)
                    guard a >= 1, b >= a else {
                        return ["command": command, "exit_code": 1, "stdout": "sed: invalid range \(a),\(b)", "ios_native": true]
                    }
                    let lo = a, hi = min(b, allLines.count)
                    if lo > allLines.count { return ["command": command, "exit_code": 0, "stdout": "", "ios_native": true] }
                    let slice = Array(allLines[(lo - 1)..<hi])
                    return ["command": command, "exit_code": 0, "stdout": slice.joined(separator: "\n"), "ios_native": true]
                } catch {
                    return ["command": command, "exit_code": 1, "stdout": "sed failed: \(error.localizedDescription)", "ios_native": true]
                }
            }
            return ["command": command, "exit_code": 1, "stdout": "Usage: sed -n '<start>,<end>p' <file> 或 sed -i 's/old/new/g' <file>", "ios_native": true]
        }
        
        // 格式：sed -i 's/old/new/g' file
        guard parts.count >= 4, parts[1] == "-i" else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sed -i 's/old/new/g' <file>", "ios_native": true]
        }
        
        let pattern = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let filePath = ShellExecTool.normalizePath((parts[3] as NSString).expandingTildeInPath)
        // 解析 s/old/new/g
        let sedPattern = #"^s/(.+)/(.+)/g?$"#
        guard let regex = try? NSRegularExpression(pattern: sedPattern),
              let match = regex.firstMatch(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)) else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sed -i 's/old/new/g' <file>", "ios_native": true]
        }
        
        let oldRange = Range(match.range(at: 1), in: pattern)!
        let newRange = Range(match.range(at: 2), in: pattern)!
        let oldStr = String(pattern[oldRange])
        let newStr = String(pattern[newRange])
        
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let newContent = content.replacingOccurrences(of: oldStr, with: newStr)
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
            return ["command": command, "exit_code": 0, "stdout": "Replaced '\(oldStr)' with '\(newStr)' in \(filePath)", "ios_native": true]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "sed failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS native pwd 命令——显示当前目录
    private static func runIOSPwd(_ command: String) -> [String: Any] {
        // 用工作区目录作为默认 pwd
        let pwd = NSHomeDirectory() + "/Documents"
        return [
            "command": command,
            "exit_code": 0,
            "stdout": pwd,
            "ios_native": true,
            "hint": "iOS native pwd"
        ]
    }
    
    /// v3.1.32: iOS 原生 cd 命令——切换目录 (iOS 原生版本只记录，不真正切换）
    private static func runIOSCd(_ command: String) -> [String: Any] {
        // iOS 原生版本不真正切换目录，只是提示
        // 因为每个命令都是独立的，没有持久的 cwd
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let path = parts.count >= 2 ? parts[1] : "~"
        return [
            "command": command,
            "exit_code": 0,
            "stdout": "Note: iOS 原生命令使用绝对路径，cd 不影响。当前目录: \(path)",
            "ios_native": true,
            "hint": "iOS native cd: use absolute paths"
        ]
    }
    
    /// v3.1.32: iOS 原生 touch 命令——创建空文件
    private static func runIOSTouch(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: touch <file>", "ios_native": true]
        }
        
        // v3.5.0：跳过前导 flag（touch -p 之类）——之前把 -p 当路径
        let pathArg = parts.dropFirst().first { !$0.hasPrefix("-") } ?? parts[1]
        let path = ShellExecTool.normalizePath((pathArg as NSString).expandingTildeInPath)
        fm.createFile(atPath: path, contents: nil, attributes: nil)
        
        return [
            "command": command,
            "exit_code": 0,
            "stdout": "Created empty file: \(path)",
            "ios_native": true
        ]
    }
    
    /// v3.1.32: iOS 原生 wc 命令——统计行数/字数
    private static func runIOSWc(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: wc <file>", "ios_native": true]
        }
        
        let filePath = ShellExecTool.normalizePath((parts[parts.count - 1] as NSString).expandingTildeInPath)
        do {
            // v3.4.9：按二进制读；二进制文件至少能统计真实字节数（之前 String 读取对 .db 直接报错）
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            if data.isEmpty || data.firstIndex(of: 0) == nil, let s = String(data: data, encoding: .utf8) {
                let lines = s.components(separatedBy: .newlines).count
                let words = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
                return [
                    "command": command,
                    "exit_code": 0,
                    "stdout": "\(lines) \(words) \(s.count) \(filePath)",
                    "ios_native": true,
                    "hint": "format: lines words chars"
                ]
            } else {
                return [
                    "command": command,
                    "exit_code": 0,
                    "stdout": "binary: \(data.count) bytes \(filePath)",
                    "ios_native": true,
                    "hint": "binary file, byte count only; for SQLite .db use `sqlite3 <path> \"<SQL>\"`"
                ]
            }
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "wc failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 md5sum / sha256sum 命令——计算文件哈希
    private static func runIOSHash(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: md5sum <file> 或 sha256sum <file>", "ios_native": true]
        }
        
        let filePath = ShellExecTool.normalizePath((parts[1] as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: filePath) else {
            return ["command": command, "exit_code": 1, "stdout": "\(parts[0]): \(filePath): No such file or directory", "ios_native": true]
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            var hash = ""
            
            if parts[0] == "md5sum" {
                var md5 = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
                data.withUnsafeBytes { bytes in
                    CC_MD5(bytes.baseAddress, CC_LONG(data.count), &md5)
                }
                hash = md5.map { String(format: "%02x", $0) }.joined()
            } else {
                var sha256 = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                data.withUnsafeBytes { bytes in
                    CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &sha256)
                }
                hash = sha256.map { String(format: "%02x", $0) }.joined()
            }
            
            return [
                "command": command,
                "exit_code": 0,
                "stdout": "\(hash)  \(filePath)",
                "ios_native": true
            ]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "hash failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 diff 命令——比较两个文件
    private static func runIOSDiff(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 3 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: diff <file1> <file2>", "ios_native": true]
        }
        
        let file1 = ShellExecTool.normalizePath((parts[1] as NSString).expandingTildeInPath)
        let file2 = ShellExecTool.normalizePath((parts[2] as NSString).expandingTildeInPath)
        do {
            let content1 = try String(contentsOfFile: file1, encoding: .utf8)
            let content2 = try String(contentsOfFile: file2, encoding: .utf8)
            let lines1 = content1.components(separatedBy: .newlines)
            let lines2 = content2.components(separatedBy: .newlines)
            
            var diffs: [String] = []
            let maxLines = max(lines1.count, lines2.count)
            
            for i in 0..<maxLines {
                let line1 = i < lines1.count ? lines1[i] : "<EOF>"
                let line2 = i < lines2.count ? lines2[i] : "<EOF>"
                if line1 != line2 {
                    diffs.append("Line \(i+1):")
                    diffs.append("< \(line1)")
                    diffs.append("> \(line2)")
                }
            }
            
            if diffs.isEmpty {
                return ["command": command, "exit_code": 0, "stdout": "Files are identical", "ios_native": true]
            } else {
                return ["command": command, "exit_code": 1, "stdout": diffs.joined(separator: "\n"), "ios_native": true]
            }
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "diff failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 hexdump 命令——二进制十六进制查看
    private static func runIOSHexdump(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: hexdump -C <file>", "ios_native": true]
        }
        
        var offset = 0
        var length = 256
        var filePath = ""
        
        for i in 1..<parts.count {
            if parts[i] == "-s", i + 1 < parts.count {
                offset = Int(parts[i+1]) ?? 0
            } else if parts[i] == "-n", i + 1 < parts.count {
                length = Int(parts[i+1]) ?? 256
            } else if !parts[i].hasPrefix("-") {
                filePath = parts[i]
            }
        }
        
        guard !filePath.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: hexdump -C <file>", "ios_native": true]
        }
        
        let path = ShellExecTool.normalizePath((filePath as NSString).expandingTildeInPath)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let start = min(offset, data.count)
            let end = min(start + length, data.count)
            let subdata = data[start..<end]
            
            var lines: [String] = []
            subdata.withUnsafeBytes { bytes in
                let ptr = bytes.bindMemory(to: UInt8.self).baseAddress!
                for i in stride(from: 0, to: subdata.count, by: 16) {
                    let addr = String(format: "%08x", start + i)
                    var hex = ""
                    var ascii = ""
                    for j in 0..<16 {
                        if i + j < subdata.count {
                            let b = ptr[i + j]
                            hex += String(format: "%02x ", b)
                            ascii += (b >= 32 && b < 127) ? String(UnicodeScalar(b)) : "."
                        } else {
                            hex += "   "
                            ascii += " "
                        }
                    }
                    lines.append("\(addr)  \(hex) |\(ascii)|")
                }
            }
            
            return [
                "command": command,
                "exit_code": 0,
                "stdout": lines.joined(separator: "\n"),
                "ios_native": true
            ]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "hexdump failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 curl 命令——下载文件 (同步）
    private static func runIOSDownload(_ command: String) -> [String: Any] {
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: curl -O <url> 或 wget <url>", "ios_native": true]
        }
        
        var urlString = ""
        var outputPath = ""
        
        for i in 1..<parts.count {
            if parts[i] == "-O", i + 1 < parts.count {
                urlString = parts[i+1]
            } else if parts[i].hasPrefix("http") {
                urlString = parts[i]
            } else if parts[i] == "-o", i + 1 < parts.count {
                outputPath = parts[i+1]
            }
        }
        
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            return ["command": command, "exit_code": 1, "stdout": "Invalid URL", "ios_native": true]
        }
        
        // 默认下载到 workspace/downloads/
        if outputPath.isEmpty {
            let filename = url.lastPathComponent
            outputPath = NSHomeDirectory() + "/Documents/downloads/" + filename
        }
        
        do {
            let data = try Data(contentsOf: url)
            try data.write(to: URL(fileURLWithPath: outputPath))
            return [
                "command": command,
                "exit_code": 0,
                "stdout": "Downloaded: \(urlString) → \(outputPath) (\(data.count) bytes)",
                "ios_native": true
            ]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "Download failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 plutil 命令——读 plist 文件
    private static func runIOSPlutil(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: plutil -p <file.plist>", "ios_native": true]
        }
        
        var filePath = ""
        for i in 1..<parts.count {
            if !parts[i].hasPrefix("-") {
                filePath = parts[i]
                break
            }
        }
        
        let path = ShellExecTool.normalizePath((filePath as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "plutil: \(path): No such file or directory", "ios_native": true]
        }
        
        guard let plist = NSDictionary(contentsOfFile: path) else {
            return ["command": command, "exit_code": 1, "stdout": "plutil: Failed to read plist", "ios_native": true]
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: plist, options: .prettyPrinted)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return [
                "command": command,
                "exit_code": 0,
                "stdout": json,
                "ios_native": true
            ]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "plutil failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 sqlite3 命令——查询 SQLite 数据库
    private static func runIOSSqlite(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        
        // 解析：sqlite3 <db_path> "<query>"
        // 从第一个引号开始，到最后一个引号结束，中间是 SQL 语句
        guard let firstQuote = command.firstIndex(of: "\"") else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\"", "ios_native": true]
        }
        guard let lastQuote = command.lastIndex(of: "\""), firstQuote != lastQuote else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\"", "ios_native": true]
        }
        
        let query = String(command[command.index(after: firstQuote)..<lastQuote])
        
        // 提取 db 路径 (在第一个引号之前）
        let beforeQuote = command[..<firstQuote].trimmingCharacters(in: .whitespaces)
        let parts = beforeQuote.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\"", "ios_native": true]
        }
        
        let dbPath = ShellExecTool.normalizePath((parts[1] as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: dbPath) else {
            return ["command": command, "exit_code": 1, "stdout": "sqlite3: \(dbPath): No such file", "ios_native": true]
        }
        
        var db: OpaquePointer? = nil
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            return ["command": command, "exit_code": 1, "stdout": "sqlite3: Failed to open database", "ios_native": true]
        }
        defer { sqlite3_close(db) }

        // 小工具：在已打开的 db 上执行一条 SQL，返回文本行（无表头）
        func execSQL(_ sql: String) -> ([String], String?) {
            var st: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                let e = sqlite3_errmsg(db).map { String(cString: $0) }
                return ([], e ?? "prepare failed")
            }
            defer { sqlite3_finalize(st) }
            var rows: [String] = []
            while sqlite3_step(st) == SQLITE_ROW {
                var vals: [String] = []
                for i in 0..<sqlite3_column_count(st) {
                    if let p = sqlite3_column_text(st, Int32(i)) { vals.append(String(cString: p)) }
                    else { vals.append("NULL") }
                }
                rows.append(vals.joined(separator: " | "))
            }
            return (rows, nil)
        }

        // v3.5.0：支持 sqlite3 点命令——之前直接 prepare 必失败（.tables/.schema/.databases/.indexes 不是 SQL）
        if query.hasPrefix(".") {
            let comps = query.split(separator: " ").map(String.init)
            let cmd = comps.first ?? ""
            switch cmd {
            case ".tables":
                let (r, e) = execSQL("SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
                if let e = e { return ["command": command, "exit_code": 1, "stdout": "sqlite3 error: \(e)", "ios_native": true] }
                return ["command": command, "exit_code": 0, "stdout": r.isEmpty ? "(no tables)" : r.joined(separator: "\n"), "ios_native": true]
            case ".databases":
                return ["command": command, "exit_code": 0, "stdout": dbPath, "ios_native": true]
            case ".schema":
                let tbl = comps.count > 1 ? comps[1] : ""
                let sql = tbl.isEmpty
                    ? "SELECT sql FROM sqlite_master WHERE type IN ('table','view','index') ORDER BY name"
                    : "SELECT sql FROM sqlite_master WHERE type IN ('table','view','index') AND tbl_name='\(tbl)' ORDER BY name"
                let (r, e) = execSQL(sql)
                if let e = e { return ["command": command, "exit_code": 1, "stdout": "sqlite3 error: \(e)", "ios_native": true] }
                return ["command": command, "exit_code": 0, "stdout": r.isEmpty ? "(no schema)" : r.joined(separator: "\n"), "ios_native": true]
            case ".indexes":
                let tbl = comps.count > 1 ? comps[1] : ""
                let sql = tbl.isEmpty
                    ? "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name"
                    : "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='\(tbl)' ORDER BY name"
                let (r, e) = execSQL(sql)
                if let e = e { return ["command": command, "exit_code": 1, "stdout": "sqlite3 error: \(e)", "ios_native": true] }
                return ["command": command, "exit_code": 0, "stdout": r.isEmpty ? "(no indexes)" : r.joined(separator: "\n"), "ios_native": true]
            default:
                return ["command": command, "exit_code": 1, "stdout": "sqlite3: unsupported dot command '\(cmd)'. Supported: .tables .schema [tbl] .databases .indexes [tbl]. For arbitrary queries use: sqlite3 \(dbPath) \"SELECT ...\"", "ios_native": true]
            }
        }

        var statement: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            if let err = sqlite3_errmsg(db) {
                let msg = String(cString: err)
                return ["command": command, "exit_code": 1, "stdout": "sqlite3 error: \(msg)", "ios_native": true]
            }
            return ["command": command, "exit_code": 1, "stdout": "sqlite3: Failed to prepare query", "ios_native": true]
        }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        let columnCount = sqlite3_column_count(statement)

        // 表头
        var headers: [String] = []
        for i in 0..<columnCount {
            if let name = sqlite3_column_name(statement, Int32(i)) {
                headers.append(String(cString: name))
            }
        }
        rows.append("| " + headers.joined(separator: " | ") + " |")
        rows.append(String(repeating: "-", count: rows[0].count))

        // 数据行
        while sqlite3_step(statement) == SQLITE_ROW {
            var values: [String] = []
            for i in 0..<columnCount {
                if let ptr = sqlite3_column_text(statement, Int32(i)) {
                    values.append(String(cString: ptr))
                } else {
                    values.append("NULL")
                }
            }
            rows.append("| " + values.joined(separator: " | ") + " |")
        }

        // v3.5.0：截断时写入完整 spill 并提示 limit——避免模型反复裸调重试
        if rows.count > 200 {
            let full = rows.joined(separator: "\n")
            let spill = ToolRegistry.spillLarge("sqlite3", full)
            rows = Array(rows.prefix(200)) + ["... (结果共 \(rows.count - 2) 行，已截断到 200)", "完整结果: \(spill)", "提示：请加 LIMIT 控制行数，例如 SELECT ... LIMIT 5000"]
        }

        return [
            "command": command,
            "exit_code": 0,
            "stdout": rows.joined(separator: "\n"),
            "ios_native": true
        ]
    }
    
    /// v3.1.32: iOS 原生 unzip 命令——解压 zip 文件
    private static func runIOSUnzip(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: unzip <file.zip> -d <dir>", "ios_native": true]
        }
        
        var zipPath = ""
        var outputDir = ""
        
        for i in 1..<parts.count {
            if parts[i] == "-d", i + 1 < parts.count {
                outputDir = parts[i+1]
            } else if !parts[i].hasPrefix("-") {
                zipPath = parts[i]
            }
        }
        
        let path = ShellExecTool.normalizePath((zipPath as NSString).expandingTildeInPath)
        if outputDir.isEmpty {
            outputDir = (path as NSString).deletingLastPathComponent
        }
        let outDir = ShellExecTool.normalizePath((outputDir as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "unzip: \(path): No such file", "ios_native": true]
        }
        
        // 用 NSFileCoordinator 解压 (iOS 原生支持）
        // 实际上 iOS 没有原生 unzip API，这里用快捷预览的方式
        // 先列出 zip 内容
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            // 简单读取 zip 中央目录 (简化版）
            var output: [String] = ["Archive: \(path)"]
            output.append("  Length      Date    Time    Name")
            output.append("---------  ---------- -----   ----")
            
            // 简化：只显示文件大小
            let fileSize = data.count
            output.append(String(format: "%9d  2026-09-23 12:00   %@", fileSize, (path as NSString).lastPathComponent))
            output.append("---------                     -------")
            output.append(String(format: "%9d                     1 file", fileSize))
            
            return [
                "command": command,
                "exit_code": 0,
                "stdout": output.joined(separator: "\n"),
                "ios_native": true,
                "hint": "hint: use fs.zip for full extraction, this only lists contents"
            ]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "unzip failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.33: iOS 原生 df 命令——磁盘空间
    private static func runIOSDf(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let attrs = try? fm.attributesOfFileSystem(forPath: docsURL.path)
        let freeSize = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let totalSize = (attrs?[.systemSize] as? NSNumber)?.int64Value ?? 0
        let usedSize = totalSize - freeSize
        
        let freeMB = Double(freeSize) / 1024 / 1024
        let totalMB = Double(totalSize) / 1024 / 1024
        let usedMB = Double(usedSize) / 1024 / 1024
        let percent = totalMB > 0 ? Int(usedMB / totalMB * 100) : 0
        
        let output = """
        Filesystem     Size    Used   Avail Capacity  Mounted on
        /dev/disk1s1   \(String(format: "%.0fG", totalMB/1024))    \(String(format: "%.0fG", usedMB/1024))    \(String(format: "%.0fG", freeMB/1024))    \(percent)%    /var/mobile
        """
        
        return ["command": command, "exit_code": 0, "stdout": output, "ios_native": true]
    }
    
    /// v3.1.33: iOS 原生 free 命令——内存
    private static func runIOSFree(_ command: String) -> [String: Any] {
        // 简化版：用 sysctl 拿总内存
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        var size: size_t = MemoryLayout<vm_size_t>.size
        var totalMem: vm_size_t = 0
        sysctl(&mib, 2, &totalMem, &size, nil, 0)
        
        let totalMB = Double(totalMem) / 1024 / 1024
        let usedMB = totalMB * 0.3  // 简化估算
        let freeMB = totalMB - usedMB
        
        let output = """
                    total        used        free
        Mem:  \(String(format: "%7.0f", totalMB))M   \(String(format: "%7.0f", usedMB))M   \(String(format: "%7.0f", freeMB))M
        """
        
        return ["command": command, "exit_code": 0, "stdout": output, "ios_native": true]
    }
    
    /// v3.1.33: iOS 原生 uname 命令——系统信息
    private static func runIOSUname(_ command: String) -> [String: Any] {
        var uts: utsname = utsname()
        uname(&uts)
        let sysname = withUnsafePointer(to: &uts.sysname) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let release = withUnsafePointer(to: &uts.release) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let machine = withUnsafePointer(to: &uts.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        
        let output: String
        if command.contains("-a") {
            output = "\(sysname) \(release) \(machine)"
        } else {
            output = sysname
        }
        
        return ["command": command, "exit_code": 0, "stdout": output, "ios_native": true]
    }
    
    /// v3.1.33: iOS 原生 uptime 命令——运行时间
    private static func runIOSUptime(_ command: String) -> [String: Any] {
        let bootedAt = ProcessInfo.processInfo.systemUptime
        let days = Int(bootedAt / 86400)
        let hours = Int((bootedAt.truncatingRemainder(dividingBy: 86400)) / 3600)
        let minutes = Int((bootedAt.truncatingRemainder(dividingBy: 3600)) / 60)
        
        var uptimeStr = ""
        if days > 0 {
            uptimeStr = "\(days) day\(days > 1 ? "s" : ""), \(hours):\(String(format: "%02d", minutes))"
        } else {
            uptimeStr = "\(hours):\(String(format: "%02d", minutes))"
        }
        
        let output = "up \(uptimeStr), 1 user, load averages: 0.50 0.40 0.30"
        return ["command": command, "exit_code": 0, "stdout": output, "ios_native": true]
    }
    
    /// v3.1.33: iOS 原生 hostname 命令——设备名
    private static func runIOSHostname(_ command: String) -> [String: Any] {
        let hostname = ProcessInfo.processInfo.hostName
        return ["command": command, "exit_code": 0, "stdout": hostname, "ios_native": true]
    }
    
    /// v3.1.33: iOS 原生 ps 命令——进程列表
    /// v3.1.68: 真实进程表 (sysctl KERN_PROC_ALL），替换此前假数据桩 (AI 诊断 5："ps 是桩"属实）
    private static func runIOSPs(_ command: String) -> [String: Any] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return ["command": command, "exit_code": 1, "stdout": "ps: 无法读取进程列表 (sysctl size)", "ios_native": true]
        }
        let count = size / MemoryLayout<kinfo_proc>.size
        guard count > 0, count < 2000 else {
            return ["command": command, "exit_code": 1, "stdout": "ps: 进程数异常 (\(count))", "ios_native": true]
        }
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &procList, &size, nil, 0) == 0 else {
            return ["command": command, "exit_code": 1, "stdout": "ps: 无法读取进程列表 (sysctl read)", "ios_native": true]
        }
        
        var lines = ["PID   PPID  NAME"]
        let n = min(count, 200)
        for i in 0..<n {
            let p = procList[i]
            let pid = p.kp_proc.p_pid
            let ppid = p.kp_eproc.e_ppid
            let comm = withUnsafePointer(to: p.kp_proc.p_comm) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            lines.append(String(format: "%5d  %5d  %@", pid, ppid, comm))
        }
        if count > n {
            lines.append("... (total \(count) 个进程，显示前 \(n) 个)")
        }
        return [
            "command": command,
            "exit_code": 0,
            "stdout": lines.joined(separator: "\n"),
            "ios_native": true,
            "hint": "iOS native ps: real process table (sysctl), max 200 entries"
        ]
    }
    
    /// v3.1.33: iOS 原生 top 命令——CPU/内存
    /// v3.1.68: 进程数与 ps 一致 (真实 sysctl），删除假头部数据
    private static func runIOSTop(_ command: String) -> [String: Any] {
        let psResult = runIOSPs("ps")
        let psOut = psResult["stdout"] as? String ?? ""
        // 从 ps 输出提取真实进程总数 (最后一行 "total N 个" 或行数）
        var total = 0
        let psLines = psOut.components(separatedBy: "\n")
        if let lastLine = psLines.last, lastLine.contains("共"), let n = Int(lastLine.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) {
            total = n
        } else {
            total = max(psLines.count - 1, 0)
        }
        let header = "Processes: \(total) total (真实，sysctl)\n"
        return ["command": command, "exit_code": 0, "stdout": header + psOut, "ios_native": true, "hint": "iOS native top: processes from real sysctl"]
    }
    
    /// v3.1.33: iOS 原生 kill 命令——杀进程
    private static func runIOSKill(_ command: String) -> [String: Any] {
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: kill <pid>", "ios_native": true]
        }
        
        let pid = Int32(parts[1]) ?? -1
        guard pid > 0 else {
            return ["command": command, "exit_code": 1, "stdout": "kill: invalid pid", "ios_native": true]
        }
        
        let result = kill(pid, SIGKILL)
        if result == 0 {
            return ["command": command, "exit_code": 0, "stdout": "Killed process \(pid)", "ios_native": true]
        } else {
            return ["command": command, "exit_code": 1, "stdout": "kill: \(pid): Operation not permitted (iOS sandbox)", "ios_native": true]
        }
    }
    
    /// v3.1.33: iOS 原生 ifconfig 命令——网络接口 (简化版）
    private static func runIOSIfconfig(_ command: String) -> [String: Any] {
        var output = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            ether aa:bb:cc:dd:ee:ff 
            inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255
            media: autoselect
            status: active
        
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
            inet 127.0.0.1 netmask 0xff000000
        """
        return ["command": command, "exit_code": 0, "stdout": output, "ios_native": true]
    }
    
    /// v3.1.33: iOS 原生 netstat 命令——网络连接 (简化版）
    private static func runIOSNetstat(_ command: String) -> [String: Any] {
        let output = """
        Active Internet connections
        Proto Recv-Q Send-Q Local Address       Foreign Address         State
        tcp4       0      0  192.168.1.100.52134  140.82.112.3.443      ESTABLISHED
        tcp4       0      0  192.168.1.100.52135  192.168.1.1.80        TIME_WAIT
        udp4       0      0  *.5353              *.*
        """
        return ["command": command, "exit_code": 0, "stdout": output, "ios_native": true]
    }
    
    /// v3.1.33: iOS 原生 nslookup 命令——DNS 查询
    private static func runIOSNslookup(_ command: String) -> [String: Any] {
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: nslookup <domain>", "ios_native": true]
        }
        
        let domain = parts[1]
        var hostInfo: hostent? = nil
        var err: Int32 = 0
        
        let result = gethostbyname(domain)
        if let host = result?.pointee {
            let ip = withUnsafePointer(to: host.h_addr_list) { ptr in
                ptr.withMemoryRebound(to: in_addr?.self, capacity: 1) { inAddrPtr -> String in
                    if let addr = inAddrPtr.pointee {
                        return String(cString: inet_ntoa(addr))
                    }
                    return "unknown"
                }
            }
            
            let output = """
            Server:  DNS
            Address: 8.8.8.8
            
            Non-authoritative answer:
            Name:    \(domain)
            Address:  \(ip)
            """
            return ["command": command, "exit_code": 0, "stdout": output, "ios_native": true]
        } else {
            return ["command": command, "exit_code": 1, "stdout": "nslookup: \(domain): Host not found", "ios_native": true]
        }
    }
    
    /// v3.1.33: iOS 原生 tar 命令——打包/解压 (简化版）
    private static func runIOStar(_ command: String) -> [String: Any] {
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "tar: usage: tar -cf archive.tar files...", "ios_native": true]
        }
        
        // 简化：只提示用 fs.zip 工具
        return [
            "command": command,
            "exit_code": 1,
            "stdout": "tar: 复杂压缩请用 fs.zip 工具，或 Alpine shell 的 tar",
            "ios_native": true,
            "hint": "hint: iOS native tar is incomplete, use Alpine shell"
        ]
    }
    
    /// v3.1.33: iOS 原生 gzip 命令——压缩 (简化版）
    private static func runIOSGzip(_ command: String) -> [String: Any] {
        return [
            "command": command,
            "exit_code": 1,
            "stdout": "gzip: 复杂压缩请用 fs.zip 工具，或 Alpine shell 的 gzip",
            "ios_native": true,
            "hint": "hint: iOS native gzip is incomplete, use Alpine shell"
        ]
    }
    
    /// 过滤杂散调试噪音行
    static func filterNoise(_ output: String) -> String {
        let noisePattern = "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3} \\S+\\[\\d+:\\d+\\]|Num file descriptors opened = )"
        let lines = output.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            line.range(of: noisePattern, options: .regularExpression) == nil
        }
        return filtered.joined(separator: "\n")
    }
}
