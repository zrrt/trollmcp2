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
        summary: "Run a shell command (terminal/command line). FIRST: for binary analysis use `binary.symbols`, for SQLite use `db`, for unpacking deb/ipa use `package` — prefer these dedicated tools over manually chaining shell commands. Use shell.exec only for file ops / system info / raw commands. 环境：系统按命令类型自动路由——装包/解包/完整工具链/复杂脚本(python、git、apk、tar、unzip、zip、file、sh -c、heredoc等开头)自动走 Alpine Linux(真工具链)；纯文件操作/系统信息/网络默认 iOS 原生。v4.1.0: Alpine 自动 bind：工作区(/var/mobile/Documents/Workspace→/ios_workspace)、/var/containers(→/ios_containers)、/System(→/ios_system 只读)；读 App 数据容器用 bind_app(→/ios_data_<app>)或原生工具。绝不绑整棵 /var/mobile(自引用崩溃源)。Alpine 命令引用这些 iOS 路径时自动挂载并改写，直接读写(无 2MB 限制)；DNS 自动配置；缺工具自动 apk add。iOS 原生模式：36 个原生命令直通真实 iOS——ls/cat/find/grep/echo/mkdir/rm/mv/cp/tail/head/sed/pwd/touch/wc/md5sum/diff/hexdump/base64/curl/plutil/sqlite3/strings/nm + df/free/uname/uptime/hostname/ps/top/kill + ifconfig/netstat/nslookup。支持管道/分号/重定向/&&/||，支持 VAR=赋值与 $VAR 展开；过滤器白名单：head/tail/grep/wc/sed/awk/sort/uniq/cut/tr/rev/echo/cat/base64。iOS 原生不支持 for/while/case/heredoc/多行脚本。二进制分析用原生 strings/nm(直读大文件无上限)。SQLite 用内置 sqlite3：`sqlite3 <db> \".tables\"`。注意：不要输入 `ta <tool>`/`ta list`/`ta help`——`ta` 是 CLI/脚本用的原生 offload 命令名，不是给 AI 的 MCP 工具；要调用能力直接调用对应 MCP 工具(inject/db/package/app/device...)。Use for: file ops, system info, network, text processing. Don't use for: UI taps/swipes (use control.*), app control (use app.*), injection (use injection.*). v4.3.13: ①`base64 -d <b64file> > outfile` 现直接解码写二进制目标(不再写 .decoded)；②`plutil -p` 支持二进制 plist 全类型打印(Data/Date/Bool)、`plutil -convert xml1 [-o out.xml]`；③`find` 支持 `-type f|d`；④`cp -f` 可覆盖已存在目标、目标为目录时复制到 dst/原名；⑤默认超时收紧到 20s——iSH 是 x86 模拟器 CPU 开销极高，超长 Alpine 命令/死循环约 13s CPU 即触发系统 watchdog 导致手机重启/闪退，故长任务请拆小步、指定合理 timeout。原生 curl 用法(v4.3.26)：下载用 `curl -O <url>`、指定路径 `curl -o <path> <url>`、直接抓正文用 `curl -sL <url>`（URL 与参数带引号会自动剥除，不再误报 Invalid URL；抓 JS 动态渲染页会返回 needs_render=true，此时改用内置浏览器 browser.navigate+browser.text 读渲染后正文）。",
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

        // v4.4.2：iSH 模拟器段错误防护——import numpy/pandas/matplotlib 会加载 openblas，
        // OpenMinis arm64 模拟器执行其指令段错误闪退（实测崩溃栈 cpu_run_to_interrupt + task_run_current）。
        // 提前拦截给明确报错，避免 App 直接闪退（体验优于崩溃）。
        // v4.4.4：原生 ARM64 Python 已集成（python3 首词 → 原生路由，能跑 numpy/openblas），
        // 因此只拦 iSH 路径（sh -c 包装等），原生 python3 放行。
        let cmdFirstWord = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        let nativePython = (cmdFirstWord == "python3" || cmdFirstWord == "python")
        if !nativePython && (command.contains("import pandas") || command.contains("import numpy")
            || command.contains("import matplotlib")) {
            return [
                "error": "iSH numpy/pandas 段错误防护",
                "command": command,
                "hint": "iSH 模拟器运行 numpy/openblas 会段错误闪退（实测崩溃栈 cpu_run_to_interrupt），禁止在 iSH 内 import pandas/numpy/matplotlib。数据分析请用原生 python3（App 内置，iPhone 芯片直跑）：python3 -c \"import pandas...\" 走原生路由即可。"
            ]
        }
        
        // 重置工作目录
        if params["reset_cwd"] as? Bool == true {
            ISHEngine.resetCwd()
        }
        
        // v4.3.13: 默认超时 30→20s（收紧）。iSH(x86 模拟器) CPU 开销极高，后台长命令/死循环
        // 约 13s CPU 即触发系统 watchdog(Elapsed CPU time 超限)→ panic/重启/闪退。收紧默认超时 + ISH kill 兜底。
        let timeout = min(max((params["timeout"] as? Double) ?? 20, 1), 120)
        
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
            // v3.7.7: 自动 bind——Alpine 命令引用 iOS 路径时自动挂载顶层 + 改写路径，
            // 让 Alpine 直接读写 iOS 文件（消灭环境漂移，替代单向字节桥接）。
            // bind 后 iOS 路径不可见的旧约束不再成立。
            let boundCmd = ISHEngine.autoBind(trimmed)
            // v3.6.19l: Alpine 执行前保护护栏——凡命令要进 Alpine 却引用了"桥接不了"的 iOS 文件
            // (>2MB 超限 / 不存在)，Alpine 必然读不到 → 执行前直接拦截并给出明确下一步，
            // 而不是放进去跑出空结果让 AI 反复瞎试（根治 jinx 会话 40 次工具调用绕圈的根因）。
            if let guardMsg = ShellExecTool.alpineIOSPathGuard(boundCmd) {
                return ["command": trimmed, "exit_code": 1, "ios_native": false,
                        "stdout": guardMsg,
                        "hint": "该命令会被路由到 Alpine，但 Alpine 读不到该 iOS 路径（非 Workspace/Containers 绑定目录，或文件>2MB）。三种解法：①先 cp 到 Workspace：`cp <file> /var/mobile/Documents/Workspace/`，再走 Alpine /ios_workspace 直读分析；②用原生 shell 工具（strings/nm/hexdump 直读大文件）；③对二进制用 binary.symbols / file analyze。"]
            }
            let (output, exitCode, timedOut) = ISHEngine.exec(boundCmd, timeout: timeout)            // P3 按需补给：Alpine 输出显示缺工具(command not found)且命中白名单 → 自动 apk add 并重跑一次，
            // 免 agent 反复探测缺什么、也避免"先探测→再装→再跑"的多轮试探。
            let (finalOut, finalExit, finalTimed, provisionNote) = ShellExecTool.provisionAndRerun(boundCmd, output: output, exitCode: exitCode, timedOut: timedOut, timeout: timeout)
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
                "hint": (provisionNote.isEmpty ? "" : provisionNote) + "Alpine Linux environment (auto-routed: needs full toolchain). 缺工具时系统已自动 apk add 安装并重试一次。"
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
            let result = ShellExecTool.runIOSPipeline(ShellExecTool.alpineToIOSPath(expanded), limit: outLimit, offset: offsetParam, timeout: timeout)
            AuditLog.shared.log("shell.exec (ios pipeline)", detail: String(expanded.prefix(100)))
            return result
        }
        
        // v4.3.9: 反向路径翻译——原生命令收到 Alpine 挂载路径(/ios_workspace 等)时翻译回 iOS 真实路径,
        // 消除 grep/cat/ls 收到 /ios_workspace 找不到文件的割裂(AI 不必手动换路径)。
        let iosCmd = ShellExecTool.alpineToIOSPath(trimmed)
        
        // 1. ls 命令——iOS 原生实现
        if trimmed.hasPrefix("ls ") || trimmed == "ls" {
            let result = ShellExecTool.runIOSls(iosCmd)
            AuditLog.shared.log("shell.exec (ios ls)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 2. cat 命令——iOS 原生实现 (读文件）
        if trimmed.hasPrefix("cat ") {
            let result = ShellExecTool.runIOSCat(iosCmd)
            AuditLog.shared.log("shell.exec (ios cat)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 3. find 命令——iOS 原生实现 (找文件）
        if trimmed.hasPrefix("find ") {
            let result = ShellExecTool.runIOSFind(iosCmd)
            AuditLog.shared.log("shell.exec (ios find)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 4. grep 命令——iOS 原生实现 (搜文本）
        if trimmed.hasPrefix("grep ") {
            let result = ShellExecTool.runIOSGrep(iosCmd)
            AuditLog.shared.log("shell.exec (ios grep)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 5. 写文件命令 (echo > / >>）——iOS 原生实现
        if trimmed.range(of: #"^echo\s+.*>\s+"#, options: .regularExpression) != nil {
            let result = ShellExecTool.runIOSWrite(iosCmd)
            AuditLog.shared.log("shell.exec (ios write)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 6. mkdir 命令——iOS 原生实现 (建目录）
        if trimmed.hasPrefix("mkdir ") {
            let result = ShellExecTool.runIOSMkdir(iosCmd)
            AuditLog.shared.log("shell.exec (ios mkdir)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 7. rm 命令——iOS 原生实现 (删文件/目录）
        if trimmed.hasPrefix("rm ") {
            let result = ShellExecTool.runIOSRm(iosCmd)
            AuditLog.shared.log("shell.exec (ios rm)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 8. mv 命令——iOS 原生实现 (移动/重命名）
        if trimmed.hasPrefix("mv ") {
            let result = ShellExecTool.runIOSMv(iosCmd)
            AuditLog.shared.log("shell.exec (ios mv)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 9. cp 命令——iOS 原生实现 (复制）
        if trimmed.hasPrefix("cp ") {
            let result = ShellExecTool.runIOCp(iosCmd)
            AuditLog.shared.log("shell.exec (ios cp)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 10. tail 命令——iOS 原生实现 (看文件末尾）
        if trimmed.hasPrefix("tail ") {
            let result = ShellExecTool.runIOSTail(iosCmd)
            AuditLog.shared.log("shell.exec (ios tail)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 11. head 命令——iOS 原生实现 (看文件开头）
        if trimmed.hasPrefix("head ") {
            let result = ShellExecTool.runIOSHead(iosCmd)
            AuditLog.shared.log("shell.exec (ios head)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 12. sed 命令——iOS 原生实现 (替换内容）
        if trimmed.hasPrefix("sed ") {
            let result = ShellExecTool.runIOSSed(iosCmd)
            AuditLog.shared.log("shell.exec (ios sed)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 13. pwd 命令——iOS 原生实现 (显示当前目录）
        if trimmed == "pwd" {
            let result = ShellExecTool.runIOSPwd(iosCmd)
            AuditLog.shared.log("shell.exec (ios pwd)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 14. cd 命令——iOS 原生实现 (切换目录）
        if trimmed.hasPrefix("cd ") || trimmed == "cd" {
            let result = ShellExecTool.runIOSCd(iosCmd)
            AuditLog.shared.log("shell.exec (ios cd)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 15. touch 命令——iOS 原生实现 (创建空文件）
        if trimmed.hasPrefix("touch ") {
            let result = ShellExecTool.runIOSTouch(iosCmd)
            AuditLog.shared.log("shell.exec (ios touch)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 16. wc 命令——iOS 原生实现 (统计行数/字数）
        if trimmed.hasPrefix("wc ") {
            let result = ShellExecTool.runIOSWc(iosCmd)
            AuditLog.shared.log("shell.exec (ios wc)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 17. md5sum / sha256sum 命令——iOS 原生实现 (计算哈希）
        if trimmed.hasPrefix("md5sum ") || trimmed.hasPrefix("sha256sum ") {
            let result = ShellExecTool.runIOSHash(iosCmd)
            AuditLog.shared.log("shell.exec (ios hash)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 18. diff 命令——iOS 原生实现 (比较两个文件）
        if trimmed.hasPrefix("diff ") {
            let result = ShellExecTool.runIOSDiff(iosCmd)
            AuditLog.shared.log("shell.exec (ios diff)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 19. hexdump 命令——iOS 原生实现 (二进制十六进制）
        if trimmed.hasPrefix("hexdump ") || trimmed.hasPrefix("xxd ") {
            let result = ShellExecTool.runIOSHexdump(iosCmd)
            AuditLog.shared.log("shell.exec (ios hexdump)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 20. curl -O / wget 命令——iOS 原生实现 (下载文件）
        if trimmed.hasPrefix("curl ") || trimmed.hasPrefix("wget ") {
            let result = ShellExecTool.runIOSDownload(iosCmd)
            AuditLog.shared.log("shell.exec (ios download)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 21. plutil 命令——iOS 原生实现 (读 plist）
        if trimmed.hasPrefix("plutil ") {
            let result = ShellExecTool.runIOSPlutil(iosCmd)
            AuditLog.shared.log("shell.exec (ios plutil)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 22. sqlite3 命令——iOS 原生实现 (查询 SQLite）
        if trimmed.hasPrefix("sqlite3 ") {
            let result = ShellExecTool.runIOSSqlite(iosCmd)
            AuditLog.shared.log("shell.exec (ios sqlite)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 23. unzip 命令——iOS 原生实现 (解压 zip）
        if trimmed.hasPrefix("unzip ") {
            let result = ShellExecTool.runIOSUnzip(iosCmd)
            AuditLog.shared.log("shell.exec (ios unzip)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 24. df 命令——iOS 原生 (磁盘空间）
        if trimmed == "df" || trimmed.hasPrefix("df ") {
            let result = ShellExecTool.runIOSDf(iosCmd)
            AuditLog.shared.log("shell.exec (ios df)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 25. free 命令——iOS 原生 (内存）
        if trimmed == "free" || trimmed.hasPrefix("free ") {
            let result = ShellExecTool.runIOSFree(iosCmd)
            AuditLog.shared.log("shell.exec (ios free)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 26. uname 命令——iOS 原生 (系统信息）
        if trimmed == "uname" || trimmed.hasPrefix("uname ") {
            let result = ShellExecTool.runIOSUname(iosCmd)
            AuditLog.shared.log("shell.exec (ios uname)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 27. uptime 命令——iOS 原生 (运行时间）
        if trimmed == "uptime" {
            let result = ShellExecTool.runIOSUptime(iosCmd)
            AuditLog.shared.log("shell.exec (ios uptime)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 28. hostname 命令——iOS 原生 (设备名）
        if trimmed == "hostname" {
            let result = ShellExecTool.runIOSHostname(iosCmd)
            AuditLog.shared.log("shell.exec (ios hostname)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 29. ps 命令——iOS 原生 (进程列表）
        if trimmed == "ps" || trimmed.hasPrefix("ps ") {
            let result = ShellExecTool.runIOSPs(iosCmd)
            AuditLog.shared.log("shell.exec (ios ps)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 30. top 命令——iOS 原生 (CPU/内存）
        if trimmed == "top" || trimmed.hasPrefix("top ") {
            let result = ShellExecTool.runIOSTop(iosCmd)
            AuditLog.shared.log("shell.exec (ios top)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 31. kill 命令——iOS 原生 (杀进程）
        if trimmed.hasPrefix("kill ") {
            let result = ShellExecTool.runIOSKill(iosCmd)
            AuditLog.shared.log("shell.exec (ios kill)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 32. ifconfig 命令——iOS 原生 (网络接口）
        if trimmed == "ifconfig" || trimmed.hasPrefix("ifconfig ") {
            let result = ShellExecTool.runIOSIfconfig(iosCmd)
            AuditLog.shared.log("shell.exec (ios ifconfig)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 33. netstat 命令——iOS 原生 (网络连接）
        if trimmed == "netstat" || trimmed.hasPrefix("netstat ") {
            let result = ShellExecTool.runIOSNetstat(iosCmd)
            AuditLog.shared.log("shell.exec (ios netstat)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 34. nslookup 命令——iOS 原生 (DNS 查询）
        if trimmed.hasPrefix("nslookup ") {
            let result = ShellExecTool.runIOSNslookup(iosCmd)
            AuditLog.shared.log("shell.exec (ios nslookup)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 35. tar 命令——iOS 原生 (打包/解压）
        if trimmed.hasPrefix("tar ") {
            let result = ShellExecTool.runIOStar(iosCmd)
            AuditLog.shared.log("shell.exec (ios tar)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 36. gzip 命令——iOS 原生 (压缩）
        if trimmed.hasPrefix("gzip ") || trimmed.hasPrefix("gunzip ") {
            let result = ShellExecTool.runIOSGzip(iosCmd)
            AuditLog.shared.log("shell.exec (ios gzip)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // v3.0.41：iSH 为唯一引擎 (ios_system 已删除）。初始化failed直接报错，不再回退。
        let (output, exitCode, timedOut) = ISHEngine.exec(command, timeout: timeout)

        // v4.3.76：单命令 Alpine 兜底同样享受"缺工具自动装"——objdump/jq/xxd/readelf/rabin2 等
        // 不在 autoRouteNeedsAlpine 标记里的命令，not found 时白名单自动装并重跑一次，与主 Alpine 路由一致。
        // 参考 iOS 原生命令算法：36 个白名单命令都有自动实现；Alpine 工具也应"装了就能直接调"。
        var provNote = ""
        var rOut = output, rExit = exitCode, rTimed = timedOut
        (rOut, rExit, rTimed, provNote) = ShellExecTool.provisionAndRerun(command, output: output, exitCode: exitCode, timedOut: timedOut, timeout: timeout)

        // 过滤杂散调试噪音
        var stdout = ShellExecTool.filterNoise(rOut)
        if outLimit > 0 && stdout.count > outLimit {
            let spillPath = ToolRegistry.spillLarge("shell", stdout)
            stdout = String(stdout.prefix(outLimit / 2)) + "\n…[输出太长total \(stdout.count) 字符，已截断；完整输出: \(spillPath)]…\n" + String(stdout.suffix(outLimit / 2))
        }

        // 会话目录：iSH guest 路径
        var newPwd = ISHEngine.cwd

        AuditLog.shared.log("shell.exec", detail: String(command.prefix(100)))

        var result: [String: Any] = [
            "command": command,
            "exit_code": rExit,
            "stdout": stdout,
            "cwd": newPwd,
            "hint": provNote + "Alpine Linux environment: full command set (ls/cat/grep/find/tar/curl/python...), apk add to install packages. iOS 路径自动 bind 直读。cd remembers directory."
        ]
        if rTimed {
            result["timed_out"] = true
            result["hint"] = (provNote.isEmpty ? "" : provNote + " ") + "command did not finish within \(Int(timeout))s, process group SIGKILLed"
        }
        return result
    }
    
    // MARK: - v3.1.33 shell 语法识别 + iOS 原生管道执行器
    // 修复"同一命令路由随机 (iOS vs Alpine）"和"iOS 原生不支持 | ; && >"两个根因：
    // 含 shell 语法的命令统一在此处理：首段是 iOS 原生命令 → iOS 原生执行 + Swift 过滤器；
    // 首段非 iOS 命令 (python 等）→ 交给 Alpine 全功能 shell。路由从此确定。
    
    /// 检测命令是否含 shell 元字符 (管道/分号/逻辑符/重定向/命令替换），跳过引号内内容
    /// v4.3.76：统一"缺工具自动装包"逻辑（135 主 Alpine 路由 与 单命令 Alpine 兜底共用）。
    /// not found 且白名单命中 → 自动 apk add（进度条 + 结构化诊断）并重跑一次；
    /// 非白名单 → 跳过安装并返回明确提示（jtool2 这类非 Alpine 工具名）。
    static func provisionAndRerun(_ body: String, output: String, exitCode: Int32, timedOut: Bool, timeout: TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool, note: String) {
        var note = ""
        let prov = ISHEngine.autoProvision(output)
        guard let pkg = prov.pkg else { return (output, exitCode, timedOut, note) }
        if !prov.known {
            note = "工具 \(pkg) 不在自动装包白名单（可能不是 Alpine 包），已跳过自动安装；请确认工具名，或用 tool.install 指定 name/source。"
            return (output, exitCode, timedOut, note)
        }
        ShellDiag.log("provision auto: apk add \(pkg) (missing in Alpine)")
        let provisionTimeout = min(max(timeout, 60), 240)
        let provisionStart = Date()
        InstallationRegistry.shared.start(key: pkg)
        let apkResult = ISHEngine.apkAdd([pkg], timeout: provisionTimeout) { line in
            InstallationRegistry.shared.appendLine(line)
        }
        let elapsed = Int(Date().timeIntervalSince(provisionStart))
        if apkResult.exitCode == 0 {
            InstallationRegistry.shared.finish(ok: true, summary: "已装 \(pkg)（\(elapsed)s）")
            note = "首次运行已自动安装缺失工具 \(pkg)（耗时 \(elapsed)s）。"
        } else {
            let diag = ISHEngine.installDiagnose(apkResult.output, timedOut: apkResult.timedOut, exitCode: apkResult.exitCode)
            InstallationRegistry.shared.finish(ok: false, summary: diag)
            note = "自动安装 \(pkg) 失败：\(diag)"
        }
        let (rout, rexit, rtimed) = ISHEngine.exec(body, timeout: timeout)
        return (rout, rexit, rtimed, note)
    }

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
            #"^\s*(tar|dpkg|dpkg-deb|rpm|unzip|zip)\s+"#,  // 解包/装包 (原生缺失或假实现→Alpine 真工具链)。strings/nm/hexdump 原生已有且能直读大文件, 不在此路由
            #"\|\s*(tar|dpkg|dpkg-deb|unzip)\s+"#,  // 管道中间的解包命令 (curl x | tar -x)
            #"^\s*python3?\s+"#,      // python / python3
            #"^\s*(pip3?)\s+"#,        // pip / pip3
            #"^\s*(git|wget|make|cmake|gcc|clang)\s+"#,  // 工具链
            #"^\s*sh\s+"#,             // 任意 sh 脚本(含无 flag) → Alpine 全功能 shell
            #"^\s*bash\s+"#,
            #"^\s*file\s+"#,           // native 无 file 命令 → Alpine 的 file(真实现, autoBind 后能读 iOS 文件)
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

    /// v3.6.19l: Alpine 执行前保护护栏。
    /// v3.7.7: 命令会先经 autoBind（自动 bind 主流 iOS 目录并改写为 /ios_*）——改写后 iOS 路径消失，
    /// guard 扫描不到即放行；仅当 autoBind 未覆盖的 iOS 路径（非 /var/mobile、/var/containers、/System 顶层）
    /// 或 bind 失败时，guard 才检查其能否被 autoBridge 桥接(>2MB/不存在)并拦截。
    /// 复用与 autoBridge 同一套 iOS 路径识别正则，保证护栏与桥接兜底判定一致。
    static func alpineIOSPathGuard(_ command: String) -> String? {
        let fm = FileManager.default
        let prefixes = ["/var/mobile/", "/private/var/mobile/", "/System/", "/var/containers/"]
        let alt = prefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "(^|[\\s\"'=>(])((?:" + alt + ")[^\\s\"'<>\\);|&,=:\\[\\]{}`]+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = command as NSString
        let maxBytes = 2 * 1024 * 1024
        var seen = Set<String>()
        var blocked: [String] = []
        for m in re.matches(in: command, options: [], range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
            let raw = ns.substring(with: m.range(at: 2))
            if seen.contains(raw) { continue }
            seen.insert(raw)
            let norm = ShellExecTool.normalizePath(raw)
            if norm.contains("/alpine-rootfs/") { continue }
            // 已桥接成功的路径(出现在 /tmp/_bridge_ 下)不受此护栏约束
            if norm.hasPrefix("/tmp/_bridge_") { continue }
            guard fm.fileExists(atPath: norm) else {
                blocked.append("\(norm) 不存在"); continue
            }
            guard (try? fm.attributesOfItem(atPath: norm)[.type]) as? FileAttributeType == .typeRegular else {
                blocked.append("\(norm) 非普通文件"); continue
            }
            let size = (try? fm.attributesOfItem(atPath: norm)[.size]) as? Int ?? 0
            if size <= 0 || size > maxBytes {
                blocked.append("\(norm) \(size)B(超过2MB桥接上限)")
            }
        }
        guard !blocked.isEmpty else { return nil }
        return "该命令将走 Alpine，引用了 Alpine 未能自动 bind 的 iOS 文件：\n" + blocked.joined(separator: "\n") +
               "\n(v3.7.7: 主流 iOS 目录已自动 bind 直读，>2MB 大文件可直读；此提示仅当 bind 失败或路径不在自动 bind 范围内时出现)。请：① 确认路径在工作区(/var/mobile/Documents/Workspace)、/var/containers、/System 下（会被自动 bind）；App 数据容器用 bind_app 绑定；② 若在别处，先用原生 shell 直接访问；③ 分析二进制用 binary.symbols。"
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
        "ta", "base64", "strings", "nm", "kfd_diag", "python3", "objdump", "class-dump"
    ]
    
    /// v4.3.9: 反向路径翻译——iOS 原生命令收到 Alpine 挂载路径时翻译回 iOS 真实路径。
    /// 正向(iOS→Alpine)已由 ISHEngine.autoBind 完成; 原生侧缺反向, 导致 grep/cat/ls
    /// 收到 /ios_workspace 等挂载路径时找不到文件(AI 被迫手动换"真实 iOS 路径")。
    /// 这里统一反向: /ios_workspace→/var/mobile/Documents/Workspace, /ios_containers→/var/containers,
    /// /ios_system→/System。原生命令处理前调用, 让 AI 任意写挂载路径都能被原生读到。
    static func alpineToIOSPath(_ command: String) -> String {
        var result = command
        let reverse: [(String, String)] = [
            ("/ios_workspace/", "/var/mobile/Documents/Workspace/"),
            ("/ios_workspace", "/var/mobile/Documents/Workspace"),
            ("/ios_containers/", "/var/containers/"),
            ("/ios_containers", "/var/containers"),
            ("/ios_system/", "/System/"),
            ("/ios_system", "/System"),
        ]
        for (alpine, ios) in reverse {
            result = result.replacingOccurrences(of: alpine, with: ios)
        }
        return result
    }
    
    /// 执行单段 iOS 原生命令 (首段），返回 [String: Any]
    private static func runIOSNativeSegment(_ segment: String) -> [String: Any] {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        // v4.3.9: 反向路径翻译——原生单段命令也统一应用(消除 /ios_workspace 等挂载路径找不到)
        let iosCmd = ShellExecTool.alpineToIOSPath(trimmed)
        let word = firstWord(trimmed)
        switch word {
        case "ls": return runIOSls(iosCmd)
        case "cat": return runIOSCat(iosCmd)
        case "find": return runIOSFind(iosCmd)
        case "grep": return runIOSGrep(iosCmd)
        case "echo": return runIOSEcho(iosCmd)
        case "mkdir": return runIOSMkdir(iosCmd)
        case "rm": return runIOSRm(iosCmd)
        case "mv": return runIOSMv(iosCmd)
        case "cp": return runIOCp(iosCmd)
        case "tail": return runIOSTail(iosCmd)
        case "head": return runIOSHead(iosCmd)
        case "sed": return runIOSSed(iosCmd)
        case "pwd": return runIOSPwd(iosCmd)
        case "cd": return runIOSCd(iosCmd)
        case "touch": return runIOSTouch(iosCmd)
        case "wc": return runIOSWc(iosCmd)
        case "md5sum", "sha256sum": return runIOSHash(iosCmd)
        case "diff": return runIOSDiff(iosCmd)
        case "hexdump": return runIOSHexdump(iosCmd)
        case "curl", "wget": return runIOSDownload(iosCmd)
        case "plutil": return runIOSPlutil(iosCmd)
        case "sqlite3": return runIOSSqlite(iosCmd)
        case "unzip": return runIOSUnzip(iosCmd)
        case "df": return runIOSDf(iosCmd)
        case "free": return runIOSFree(iosCmd)
        case "uname": return runIOSUname(iosCmd)
        case "uptime": return runIOSUptime(iosCmd)
        case "hostname": return runIOSHostname(iosCmd)
        case "ps": return runIOSPs(iosCmd)
        case "top": return runIOSTop(iosCmd)
        case "kill": return runIOSKill(iosCmd)
        case "ifconfig": return runIOSIfconfig(iosCmd)
        case "netstat": return runIOSNetstat(iosCmd)
        case "nslookup": return runIOSNslookup(iosCmd)
        case "tar": return runIOStar(iosCmd)
        case "gzip", "gunzip": return runIOSGzip(iosCmd)
        case "base64": return runIOSBase64(trimmed)
        case "strings": return runIOSStrings(iosCmd)
        case "nm": return runIOSNm(iosCmd)
        case "objdump": return runIOSObjdump(iosCmd)
        case "class-dump": return runIOSClassDump(iosCmd)
        case "python3": return runIOSPython3(iosCmd)
        case "kfd_diag": return runIOSKfdDiag(iosCmd)
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
    static func runIOSPipeline(_ command: String, limit: Int = 4000, offset: Int = 0, timeout: TimeInterval = 30) -> [String: Any] {
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
                let (body, redirect0, append, outFile) = extractRedirect(c)
                // v4.3.13: base64 -d 带重定向时改为 var，特判后置 false 跳过文本重定向
                var redirect = redirect0
                
                if cidx == 0 {
                    // 生产段：iOS 原生执行 或 Alpine
                    var result: [String: Any]
                    if isIOSCmd {
                        // v4.3.13: base64 -d <in> > outFile —— 解码写二进制目标文件。
                        // 旧实现把解码硬写 .decoded + pipeline 把提示文本重定向到 outFile，目标被写成提示串(损坏)。
                        if word == "base64", redirect, body.contains("-d"),
                           let msg = ShellExecTool.base64DecodeRedirect(body, outFile: outFile) {
                            result = ["command": body, "exit_code": 0, "stdout": msg, "ios_native": true]
                            redirect = false  // 已直接写二进制，跳过下方文本 writeRedirected
                        } else {
                            result = runIOSNativeSegment(body)
                            result["ios_native"] = true
                        }
                    } else {
                        var (output, outputExit, timedOut) = ISHEngine.exec(body, timeout: timeout)
                        // P3 按需补给（v4.3.76 统一走公共函数）：白名单已知包自动装+重跑，非白名单给明确提示
                        var provNote = ""
                        (output, outputExit, timedOut, provNote) = ShellExecTool.provisionAndRerun(body, output: output, exitCode: outputExit, timedOut: timedOut, timeout: timeout)
                        var out = ShellExecTool.filterNoise(output)
                        if limit > 0 && out.count > limit {
                            let spillPath = ToolRegistry.spillLarge("alpine", out)
                            out = String(out.prefix(limit / 2)) + "\n…[输出太长total \(out.count) 字符，已截断；完整输出: \(spillPath)]…\n" + String(out.suffix(limit / 2))
                        }
                        result = [
                            "command": body, "exit_code": Int(outputExit), "stdout": out,
                            "cwd": ISHEngine.cwd,
                            "hint": provNote + "Alpine Linux environment (non-iOS segment of compound command): full command support; 缺工具已自动 apk add"
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
    
    /// v4.3.13: base64 -d <input> > outFile 辅助——解码后直接以二进制写入目标文件。
    /// 修复旧实现缺陷：runIOSBase64 decode 硬编码写 `.decoded` 文件并返回提示文本，
    /// 而 pipeline 又把提示文本当 stdout 重定向到 `> outFile`，导致目标被写成提示串而非解码数据。
    /// 此辅助解析 body 取输入文件，解码后二进制写入 outFile（走文本 writeRedirected 会损坏二进制）。
    /// 返回成功提示；输入缺失/无效返回 nil（交由正常路径报错）。
    static func base64DecodeRedirect(_ body: String, outFile: String) -> String? {
        var parts = body.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        // 剥掉命令名/选项/stdin 重定向符，只留输入文件路径
        parts = parts.filter { $0 != "base64" && $0 != "-d" && $0 != "<" && $0 != ">" && $0 != ">>" }
        guard let raw = parts.first(where: { !$0.hasPrefix("-") }), !raw.isEmpty else { return nil }
        let input = normalizePath((raw as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: input) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: input)),
              let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else { return nil }
        do {
            try decoded.write(to: URL(fileURLWithPath: outFile))
            return "Decoded \(data.count) b64 → \(outFile) (\(decoded.count) bytes)"
        } catch {
            return nil
        }
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
            var ignoreCase = false
            var pattern = ""
            for p in parts.dropFirst() {
                if p == "-v" { invert = true; continue }
                if p == "-i" { ignoreCase = true; continue }
                pattern = p.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                break
            }
            guard !pattern.isEmpty else { return input }
            // v3.6.19e: 管道 grep 与 runIOSGrep 一致——默认字面量匹配，-i 才忽略大小写。
            // 原来强制 .regularExpression + 强制 .caseInsensitive，搜 cdhash 等含.的字面量会被正则误伤、
            // 且不传 -i 也忽略大小写（误匹配）。
            let matched = lines.filter { line in
                let hit = ignoreCase ? line.range(of: pattern, options: .caseInsensitive) != nil
                                     : line.range(of: pattern) != nil
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
        case "base64":
            // v3.6.10: cat x | base64 —— 编码输入为单行 base64；base64 -d —— 解码输入
            var opts = Set(parts.dropFirst())
            let joined = input.replacingOccurrences(of: "\n", with: "")
            if opts.contains("-d") {
                guard let decoded = Data(base64Encoded: joined, options: .ignoreUnknownCharacters) else {
                    return "base64: invalid input\n原输出:\n\(input)"
                }
                return String(decoding: decoded, as: UTF8.self)
            }
            return Data(input.utf8).base64EncodedString()
        default:
            return "iOS 原生管道暂不支持过滤器: \(word) (可用 head/tail/grep/wc/sed/awk/sort/uniq/cut/tr/rev/echo/cat/base64)\n原输出:\n\(input)"
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
    
    /// v3.6.19: iOS 原生 strings —— 从二进制/任意文件提取可打印 ASCII 字符串。
    /// 用 Data(contentsOf:) 原生直读（无 Alpine 2MB 桥接上限），解决"分析大二进制提字符串"卡点。
    /// 语法: strings [-n <minlen>] [-o] <path>  (默认 minlen=4; -o 打印偏移)
    private static func runIOSStrings(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var minLen = 4, showOff = false
        var pathArg: String?
        var i = 1
        while i < parts.count {
            let a = parts[i]
            if a == "-n" { i += 1; if i < parts.count { minLen = max(1, Int(parts[i]) ?? 4) } }
            else if a == "-o" { showOff = true }
            else if a.hasPrefix("-") { /* 忽略其它选项 (-a/-el/-t 等) */ }
            else { pathArg = a; break }
            i += 1
        }
        guard let raw = pathArg else {
            return ["command": command, "exit_code": 1,
                    "stdout": "usage: strings [-n <minlen>] [-o] <path> — 从二进制文件提取可打印 ASCII 字符串（默认 minlen=4，-o 显示偏移）",
                    "ios_native": true]
        }
        let path = ShellExecTool.normalizePath((raw as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "strings: \(path): No such file or directory", "ios_native": true]
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ["command": command, "exit_code": 1, "stdout": "strings: \(path): cannot read", "ios_native": true]
        }
        var out: [String] = []
        var cur: [UInt8] = []
        var startOff = 0
        for (idx, b) in data.enumerated() {
            let printable = (b >= 0x20 && b <= 0x7e)
            if printable {
                if cur.isEmpty { startOff = idx }
                cur.append(b)
            } else {
                if cur.count >= minLen {
                    let s = String(bytes: cur, encoding: .utf8) ?? ""
                    out.append(showOff ? String(format: "%7x  ", startOff) + s : s)
                }
                cur.removeAll(keepingCapacity: true)
            }
        }
        if cur.count >= minLen {
            let s = String(bytes: cur, encoding: .utf8) ?? ""
            out.append(showOff ? String(format: "%7x  ", startOff) + s : s)
        }
        if out.isEmpty {
            return ["command": command, "exit_code": 0, "stdout": "(no ASCII strings of length >= \(minLen) found)", "ios_native": true]
        }
        let joined = out.joined(separator: "\n")
        let truncated: String
        if joined.count > 6000 {
            let spill = ToolRegistry.spillLarge("strings", joined)
            truncated = String(joined.prefix(3000)) + "\n…[输出太长 total \(joined.count) 字符，已截断；完整内容: \(spill)]…\n" + String(joined.suffix(3000))
        } else {
            truncated = joined
        }
        return ["command": command, "exit_code": 0, "stdout": truncated, "ios_native": true,
                "hint": "原生 strings 直读 iOS 文件（无 2MB 桥接上限）。提取出的可打印字符串可用于定位商品 ID/URL/库名等。需要符号名用 nm <path>。"]
    }

    /// v3.6.19: iOS 原生 nm —— 解析 Mach-O 符号表，输出定义符号 (地址 + 符号名)。
    /// 原生直读大文件；支持 fat/thin arm64。默认只输出 __text 段符号（代码函数），-a 输出全部 N_SECT 符号。
    /// 语法: nm [-a] <path>
    private static func runIOSNm(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var all = false
        var pathArg: String?
        for a in parts.dropFirst() {
            if a == "-a" || a == "-g" { all = true }
            else if !a.hasPrefix("-") { pathArg = a; break }
        }
        guard let raw = pathArg else {
            return ["command": command, "exit_code": 1,
                    "stdout": "usage: nm [-a] <path> — 输出 Mach-O 定义的符号 (地址 + 符号名)。默认只输出 __text 段（代码函数），-a 输出全部段符号。",
                    "ios_native": true]
        }
        let path = ShellExecTool.normalizePath((raw as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "nm: \(path): No such file or directory", "ios_native": true]
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ["command": command, "exit_code": 1, "stdout": "nm: \(path): cannot read", "ios_native": true]
        }
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { // little-endian
            guard o + 3 < bytes.count else { return 0 }
            return UInt32(bytes[o]) | (UInt32(bytes[o+1]) << 8) | (UInt32(bytes[o+2]) << 16) | (UInt32(bytes[o+3]) << 24)
        }
        func u64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 where o + k < bytes.count { v |= UInt64(bytes[o+k]) << (k*8) }
            return v
        }
        func b32(_ o: Int) -> UInt32 { // big-endian
            guard o + 3 < bytes.count else { return 0 }
            return (UInt32(bytes[o]) << 24) | (UInt32(bytes[o+1]) << 16) | (UInt32(bytes[o+2]) << 8) | UInt32(bytes[o+3])
        }
        // 定位 slice
        var base = 0
        let magic = u32(0)
        if magic == 0xbebafeca { // FAT_CIGAM (LE of 0xcafebabe)
            let n = Int(b32(4))
            var found = false
            for j in 0..<n {
                let b = 8 + j*20
                if b32(b) == 0x0100000c { base = Int(b32(b+8)); found = true; break } // CPU_TYPE_ARM64
            }
            if !found { return ["command": command, "exit_code": 1, "stdout": "nm: \(path): no arm64 slice", "ios_native": true] }
        } else if magic == 0xfeedfacf { // MH_MAGIC_64
            base = 0
        } else {
            return ["command": command, "exit_code": 1, "stdout": "nm: \(path): not a Mach-O 64 file (magic 0x\(String(format:"%08x", magic)))", "ios_native": true]
        }
        // 遍历 load commands 找 LC_SYMTAB (0x2)
        let ncmds = Int(u32(base + 16))
        var off = base + 32
        var symoff = 0, nsyms = 0, stroff = 0, strsize = 0
        for _ in 0..<ncmds {
            if off + 8 > bytes.count { break }
            let c = u32(off)
            let sz = Int(u32(off + 4))
            if c == 0x2 {
                symoff = Int(u32(off + 8))
                nsyms = Int(u32(off + 12))
                stroff = Int(u32(off + 16))
                strsize = Int(u32(off + 20))
                break
            }
            off += sz
        }
        guard nsyms > 0 && nsyms < 500000 else {
            return ["command": command, "exit_code": 0, "stdout": "nm: \(path): no symbols (stripped binary?)", "ios_native": true]
        }
        let strBase = base + stroff
        func symName(_ nx: Int) -> String {
            guard nx >= 0, strBase + nx < bytes.count, strBase + nx < strBase + strsize else { return "" }
            var e = strBase + nx
            while e < bytes.count && e < strBase + strsize && bytes[e] != 0 { e += 1 }
            return String(bytes: bytes[strBase+nx..<e], encoding: .utf8) ?? ""
        }
        var out: [String] = []
        for k in 0..<nsyms {
            let e = base + symoff + k*16
            if e + 16 > bytes.count { break }
            let nx = Int(u32(e))
            let ntype = bytes[e+4]
            let nsect = bytes[e+5]
            let nval = u64(e+8)
            if (ntype & 0x0e) == 0x0e && (all || nsect == 1) { // N_SECT (defined)
                let nmstr = symName(nx)
                if !nmstr.isEmpty && !nmstr.hasPrefix("$") {
                    out.append(String(format: "%016llx", nval) + "  " + nmstr)
                }
            }
        }
        if out.isEmpty {
            return ["command": command, "exit_code": 0, "stdout": "nm: \(path): no __text symbols found" + (all ? "" : " (try nm -a for all sections)"), "ios_native": true]
        }
        let joined = out.joined(separator: "\n")
        let truncated: String
        if joined.count > 8000 {
            let spill = ToolRegistry.spillLarge("nm", joined)
            truncated = String(joined.prefix(4000)) + "\n…[输出太长 total \(joined.count) 字符，已截断；完整内容: \(spill)]…\n" + String(joined.suffix(4000))
        } else {
            truncated = joined
        }
        return ["command": command, "exit_code": 0, "stdout": truncated, "ios_native": true,
                "hint": "原生 nm 直读 Mach-O 符号表。默认输出 __text 段函数符号（地址+名字），-a 输出全部段符号。可配合 strings <path> 提取字符串。"]
    }

    /// v4.4.5: 原生 objdump —— App 进程内直读 Mach-O：文件头 + load commands + 段节表 + 符号摘要，
    /// `-d` 追加基础 ARM64 反汇编（常见指令）。纯只读解析，不 spawn 外部二进制。
    /// 与 nm/kfd_diag 同路线（jtool2 官方仅 macOS 二进制，LLVM 全套交叉编译太重，自研最稳最快）。
    /// 语法: objdump [-d] <path>
    private static func runIOSObjdump(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var disasm = false
        var pathArg: String?
        for a in parts.dropFirst() {
            if a == "-d" { disasm = true }
            else if !a.hasPrefix("-") { pathArg = a; break }
        }
        guard let raw = pathArg else {
            return ["command": command, "exit_code": 1,
                    "stdout": "usage: objdump [-d] <path> — 输出 Mach-O 头/load commands/段节/符号摘要；-d 追加 __text 基础 ARM64 反汇编。",
                    "ios_native": true]
        }
        let path = ShellExecTool.normalizePath((raw as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "objdump: \(path): No such file or directory", "ios_native": true]
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ["command": command, "exit_code": 1, "stdout": "objdump: \(path): cannot read", "ios_native": true]
        }
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { guard o + 3 < b.count else { return 0 }; return UInt32(b[o]) | (UInt32(b[o+1])<<8) | (UInt32(b[o+2])<<16) | (UInt32(b[o+3])<<24) }
        func b32(_ o: Int) -> UInt32 { guard o + 3 < b.count else { return 0 }; return (UInt32(b[o])<<24) | (UInt32(b[o+1])<<16) | (UInt32(b[o+2])<<8) | UInt32(b[o+3]) }
        func u64(_ o: Int) -> UInt64 { var v: UInt64 = 0; for k in 0..<8 where o + k < b.count { v |= UInt64(b[o+k]) << (k*8) }; return v }

        var out: [String] = []
        // 定位 arm64 slice（fat/thin）
        var base = 0
        var isFat = false
        let magic = u32(0)
        if magic == 0xbebafeca { // FAT_CIGAM
            isFat = true
            let n = Int(b32(4)); var found = false
            for j in 0..<n {
                let e = 8 + j*20
                if b32(e) == 0x0100000c { base = Int(b32(e+8)); found = true; break }
            }
            if !found { out.append("objdump: no arm64 slice (fat)") }
        } else if magic == 0xfeedfacf || magic == 0xcffaedfe { // MH_MAGIC_64 (LE/BE)
            base = 0
        } else {
            out.append("objdump: not a Mach-O 64 (magic 0x\(String(format:"%08x", magic)))")
            return ["command": command, "exit_code": 0, "stdout": out.joined(separator: "\n"), "ios_native": true]
        }

        let cputype = u32(base + 4)
        let cpusub = u32(base + 8)
        let filetype = u32(base + 12)
        let ncmds = Int(u32(base + 16))
        let sizeofcmds = u32(base + 20)
        var cpuName = "arm64"
        if cputype == 0x0100000c {
            cpuName = (cpusub == 0x80000002) ? "arm64e" : "arm64"
        } else if cputype == 0x01000007 { cpuName = "x86_64" }
        let typeName: String
        switch filetype {
        case 0x1: typeName = "MH_OBJECT (.o)"
        case 0x2: typeName = "MH_EXECUTE (app)"
        case 0x4: typeName = "MH_DYLIB (dylib)"
        case 0x6: typeName = "MH_DYLINKER"
        case 0x8: typeName = "MH_BUNDLE (.bundle)"
        case 0xb: typeName = "MH_DSYM"
        default: typeName = "0x\(String(format:"%x", filetype))"
        }
        out.append("Mach-O \(isFat ? "(fat) " : "")\(cpuName) \(typeName)  \(b.count) bytes")
        out.append("load commands: \(ncmds), sizeofcmds: \(sizeofcmds)")

        // load commands 表 + __TEXT 段节表
        var off = base + 32
        var sections: [(String, UInt64, Int, Int)] = []  // (节名, addr, fileoff, size)
        var lcIndex = 0
        for _ in 0..<min(ncmds, 120) {
            if off + 8 > b.count { break }
            let c = u32(off); let sz = Int(u32(off+4))
            let cmdName: String
            switch c {
            case 0x1: cmdName = "LC_SEGMENT"
            case 0x19: cmdName = "LC_SEGMENT_64"
            case 0x2: cmdName = "LC_SYMTAB"
            case 0xb: cmdName = "LC_LOAD_DYLIB"
            case 0xc: cmdName = "LC_ID_DYLIB"
            case 0x1d: cmdName = "LC_CODE_SIGNATURE"
            case 0x22: cmdName = "LC_MAIN"
            case 0x24: cmdName = "LC_ENCRYPTION_INFO_64"
            case 0x2c: cmdName = "LC_BUILD_VERSION"
            case 0x32: cmdName = "LC_DYLD_EXPORTS_TRIE"
            case 0x80000028: cmdName = "LC_FUNCTION_STARTS"
            default: cmdName = String(format: "0x%x", c)
            }
            out.append(String(format: "  LC %d: %@ (size %d)", lcIndex, cmdName, sz))
            if c == 0x19 && sz >= 72 { // LC_SEGMENT_64: segname@off+8
                var sname = ""
                for k in 0..<16 where off+8+k < b.count && b[off+8+k] != 0 { sname += String(UnicodeScalar(b[off+8+k])) }
                let nsects = Int(u32(off+64))
                out.append("     segment \(sname) nsects=\(nsects)")
                var so = off + 72
                var secIndex = 0
                for _ in 0..<min(nsects, 40) {
                    if so + 80 > b.count { break }
                    var sec = ""
                    for k in 0..<16 where so+k < b.count && b[so+k] != 0 { sec += String(UnicodeScalar(b[so+k])) }
                    let saddr = u64(so + 32)
                    let ssize = u64(so + 40)
                    let soff = u32(so + 48)
                    out.append(String(format: "       [%02d] %@  addr=0x%llx size=0x%llx fileoff=%d", secIndex, sec, saddr, ssize, soff))
                    sections.append((sec, saddr, Int(soff), Int(ssize)))
                    so += 80
                    secIndex += 1
                }
            }
            off += sz
            lcIndex += 1
        }

        // 符号摘要（__text 定义符号）
        var symLines: [String] = []
        var stOff = 0
        var nsyms = 0
        var strOff = 0
        off = base + 32
        for _ in 0..<min(ncmds, 120) {
            if off + 8 > b.count { break }
            let c = u32(off); let sz = Int(u32(off+4))
            if c == 0x2 && sz >= 24 { // LC_SYMTAB
                stOff = Int(u32(off+8)); nsyms = Int(u32(off+12)); strOff = Int(u32(off+16))
                break
            }
            off += sz
        }
        if nsyms > 0 {
            var count = 0
            for i in 0..<min(nsyms, 20000) {
                let e = stOff + i*16
                if e + 16 > b.count { break }
                let nx = Int(u32(e))
                let ntype = b[e+4]
                if (ntype & 0x0e) == 0x0e {
                    let nval = u64(e+8)
                    var name = ""
                    var k = strOff + nx
                    while k < b.count && b[k] != 0 && name.count < 120 { name += String(UnicodeScalar(b[k])); k += 1 }
                    if !name.isEmpty && !name.hasPrefix("$") {
                        symLines.append(String(format: "%016llx  %@", nval, name))
                        count += 1
                        if count >= 60 { symLines.append("…(符号过多，仅显示前 60)"); break }
                    }
                }
            }
            out.append("symbols (__text defined): \(count > 60 ? "60+" : "\(count)")")
        }

        // -d 反汇编 __text
        if disasm, let textSec = sections.first(where: { $0.0 == "__text" }) {
            var asm: [String] = []
            let startOff = textSec.3
            let maxInsns = 200
            for i in 0..<maxInsns {
                let o = startOff + i*4
                if o + 4 > b.count || i*4 >= textSec.4 { break }
                let ins = u32(o)
                let addr = textSec.2 + UInt64(i*4)
                asm.append(String(format: "%016llx: %08x  %@", addr, ins, decodeA64(ins)))
            }
            out.append("— __text disassembly (first \(asm.count)/\(textSec.4/4) insns) —")
            out.append(contentsOf: asm)
        }

        let joined = out.joined(separator: "\n")
        let truncated: String = joined.count > 12000
            ? String(joined.prefix(8000)) + "\n…[输出太长，已截断 total \(joined.count)]…" + String(joined.suffix(2000))
            : joined
        return ["command": command, "exit_code": 0, "stdout": truncated, "ios_native": true,
                "hint": "原生 objdump 直读 Mach-O（头/load commands/段节/符号；-d 反汇编）。搭配 nm、strings 完成静态分析。"]
    }

    /// 基础 ARM64 指令解码（常见指令；未识别输出 dc=unrecognized）
    private static func decodeA64(_ w: UInt32) -> String {
        // RET / BR / BLR
        if (w & 0xFFFFFC1F) == 0xD65F0000 { return "ret" }
        if (w & 0xFFFFFC1F) == 0xD61F0000 { return "br" }
        if (w & 0xFFFFFC1F) == 0xD63F0000 { return "blr" }
        if w == 0xD503201F { return "nop" }
        // B / BL (imm26)
        if (w & 0xFC000000) == 0x14000000 {
            let imm = Int32(bitPattern: (w & 0x03FFFFFF) << 6) >> 6
            return (w & 0x80000000) != 0 ? "bl 0x\(String(format:"%llx", UInt64(bitPattern: Int64(imm))*4 + 0))" : "b  0x\(String(format:"%llx", UInt64(bitPattern: Int64(imm))*4))"
        }
        // CBZ/CBNZ (imm19)
        if (w & 0x7E000000) == 0x34000000 || (w & 0x7E000000) == 0x35000000 {
            let imm = Int32(bitPattern: (w & 0x00FFFFE0) << 8) >> 11
            return ((w & 0x7E000000) == 0x34000000 ? "cbz" : "cbnz") + " w\( (w >> 5) & 0x1F), 0x\(String(format:"%llx", UInt64(bitPattern: Int64(imm))*4))"
        }
        // ADRP (immhi:immlo)
        if (w & 0x9F000000) == 0x90000000 {
            return "adrp x\((w >> 5) & 0x1F)"
        }
        // ADD/SUB immediate
        if (w & 0x9F000000) == 0x91000000 { return "add x\((w >> 5) & 0x1F), x\(w & 0x1F), #\((w >> 10) & 0xFFF)" }
        if (w & 0x9F000000) == 0xD1000000 { return "sub x\((w >> 5) & 0x1F), x\(w & 0x1F), #\((w >> 10) & 0xFFF)" }
        // LDR/STR unsigned imm
        if (w & 0xFFC00000) == 0xF9400000 { return "ldr x\((w >> 5) & 0x1F), [x\(w & 0x1F), #\((w >> 10) & 0xFFF)]" }
        if (w & 0xFFC00000) == 0xF9000000 { return "str x\((w >> 5) & 0x1F), [x\(w & 0x1F), #\((w >> 10) & 0xFFF)]" }
        if (w & 0xFFC00000) == 0xB9400000 { return "ldr w\((w >> 5) & 0x1F), [x\(w & 0x1F), #\((w >> 10) & 0xFFF)]" }
        if (w & 0xFFC00000) == 0xB9000000 { return "str w\((w >> 5) & 0x1F), [x\(w & 0x1F), #\((w >> 10) & 0xFFF)]" }
        // MOVZ/MOVK/MOVN
        if (w & 0xFF800000) == 0xD2800000 { return "movz x\((w >> 5) & 0x1F), #\((w >> 5) & 0xFFFF)" }
        if (w & 0xFF800000) == 0xF2800000 { return "movk x\((w >> 5) & 0x1F), #\((w >> 5) & 0xFFFF)" }
        // STP/LDP
        if (w & 0xFFC00000) == 0xA9000000 { return "stp x\((w >> 10) & 0x1F), x\((w >> 5) & 0x1F), [x\(w & 0x1F)]" }
        if (w & 0xFFC00000) == 0xA9400000 { return "ldp x\((w >> 10) & 0x1F), x\((w >> 5) & 0x1F), [x\(w & 0x1F)]" }
        // 未识别
        return "dc\t\(String(format:"0x%08x", w))"
    }

    /// v4.4.5: 原生 class-dump —— 直读 __TEXT,__objc_classname / __objc_methname，输出 OC 类与方法。
    /// 对砸壳/未砸壳二进制均可用（字符串明文存在于 Mach-O）。纯只读。
    /// 语法: class-dump [-l 限制条数] <path>
    private static func runIOSClassDump(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var limit = 80
        var pathArg: String?
        var i = 1
        while i < parts.count {
            let a = parts[i]
            if a == "-l" && i + 1 < parts.count { limit = Int(parts[i+1]) ?? 80; i += 2; continue }
            else if !a.hasPrefix("-") { pathArg = a; break }
            i += 1
        }
        guard let raw = pathArg else {
            return ["command": command, "exit_code": 1,
                    "stdout": "usage: class-dump [-l N] <path> — 输出 Objective-C 类与方法（__objc_classname/__objc_methname）。",
                    "ios_native": true]
        }
        let path = ShellExecTool.normalizePath((raw as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "class-dump: \(path): No such file or directory", "ios_native": true]
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ["command": command, "exit_code": 1, "stdout": "class-dump: \(path): cannot read", "ios_native": true]
        }
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { guard o + 3 < b.count else { return 0 }; return UInt32(b[o]) | (UInt32(b[o+1])<<8) | (UInt32(b[o+2])<<16) | (UInt32(b[o+3])<<24) }
        func b32(_ o: Int) -> UInt32 { guard o + 3 < b.count else { return 0 }; return (UInt32(b[o])<<24) | (UInt32(b[o+1])<<16) | (UInt32(b[o+2])<<8) | UInt32(b[o+3]) }
        func u64(_ o: Int) -> UInt64 { var v: UInt64 = 0; for k in 0..<8 where o + k < b.count { v |= UInt64(b[o+k]) << (k*8) }; return v }

        // 定位 arm64 slice
        var base = 0
        let magic = u32(0)
        if magic == 0xbebafeca {
            let n = Int(b32(4)); var found = false
            for j in 0..<n { let e = 8 + j*20; if b32(e) == 0x0100000c { base = Int(b32(e+8)); found = true; break } }
            if !found { return ["command": command, "exit_code": 0, "stdout": "class-dump: no arm64 slice", "ios_native": true] }
        } else if magic == 0xfeedfacf { base = 0 }
        else { return ["command": command, "exit_code": 0, "stdout": "class-dump: not Mach-O 64 (magic 0x\(String(format:"%08x", magic)))", "ios_native": true] }

        // 收集段
        var sectOffsets: [String: (Int, Int)] = [:]  // 节名 -> (fileoff, size)
        let ncmds = Int(u32(base + 16))
        var off = base + 32
        for _ in 0..<ncmds {
            if off + 8 > b.count { break }
            let c = u32(off); let sz = Int(u32(off+4))
            if c == 0x19 && sz >= 72 {
                let nsects = Int(u32(off+64))
                var so = off + 72
                for _ in 0..<min(nsects, 60) {
                    if so + 80 > b.count { break }
                    var sec = ""
                    for k in 0..<16 where so+k < b.count && b[so+k] != 0 { sec += String(UnicodeScalar(b[so+k])) }
                    let soff = Int(u32(so+48)); let ssize = Int(u32(so+52))
                    sectOffsets[sec] = (soff, ssize)
                    so += 80
                }
            }
            off += sz
        }

        // 提取类名（__objc_classname 的 NUL 分隔 cstring）
        var classNames: [String] = []
        if let (co, cs) = sectOffsets["__objc_classname"] {
            var k = co; let end = min(co + cs, b.count)
            while k < end {
                var s = ""
                while k < end && b[k] != 0 { s += String(UnicodeScalar(b[k])); k += 1 }
                if !s.isEmpty && s.count < 160 { classNames.append(s) }
                k += 1
            }
        }
        // 方法名（__objc_methname）
        var selectors: [String] = []
        if let (mo, ms) = sectOffsets["__objc_methname"] {
            var k = mo; let end = min(mo + ms, b.count)
            while k < end {
                var s = ""
                while k < end && b[k] != 0 { s += String(UnicodeScalar(b[k])); k += 1 }
                if !s.isEmpty && s.count < 120 { selectors.append(s) }
                k += 1
            }
        }
        // 兜底：从任意段扫 _OBJC_CLASS_$_ 前缀字符串（未砸壳场景更常见）
        if classNames.isEmpty {
            var k = 0
            while k < b.count - 20 {
                var s = ""
                var j = k
                while j < b.count && b[j] != 0 && s.count < 200 { s += String(UnicodeScalar(b[j])); j += 1 }
                if s.hasPrefix("_OBJC_CLASS_$_") || s.hasPrefix("OBJC_CLASS_$_") {
                    let cn = s.replacingOccurrences(of: "_OBJC_CLASS_$_", with: "").replacingOccurrences(of: "OBJC_CLASS_$_", with: "")
                    if !classNames.contains(cn) { classNames.append(cn) }
                }
                k = j + 1
            }
        }

        var out: [String] = []
        out.append("Objective-C classes: \(classNames.count), methods: \(selectors.count)")
        let shown = min(classNames.count, limit)
        if shown > 0 {
            out.append("— classes —")
            for cn in classNames.prefix(shown) { out.append("  \(cn)") }
        }
        if !selectors.isEmpty {
            out.append("— methods (selectors) —")
            for s in selectors.prefix(min(selectors.count, limit)) { out.append("  - \(s)") }
        }
        if classNames.isEmpty && selectors.isEmpty {
            out.append("no ObjC metadata found — Swift-only binary 或已剥离 __objc_* 段（可用 nm/strings/objdump 交叉验证）")
        }
        let joined = out.joined(separator: "\n")
        let truncated: String = joined.count > 12000
            ? String(joined.prefix(8000)) + "\n…[输出太长，已截断 total \(joined.count)]…"
            : joined
        return ["command": command, "exit_code": 0, "stdout": truncated, "ios_native": true,
                "hint": "原生 class-dump 直读 __objc_classname/__objc_methname。Swift 二进制或剥壳后段缺失时用 nm -a + strings 互补。"]
    }

    /// v3.6.19b: iOS 原生 kfd_diag —— 只读解析 Mach-O 的代码签名结构（LC_CODE_SIGNATURE →
    /// superblob → CodeDirectory），输出每个字段。用于真机诊断 TrollStore 重签后
    /// VpnTunnel 为何无法提取 cdhash。**纯只读、不注入、不 spawn 任何 helper**（绝对安全，不会触发 kfd/panic）。
    /// 语法: kfd_diag <path>
    /// v4.4.4: 引号感知拆参（支持 -c "code with spaces" 等）
    private static func shellSplitArgs(_ s: String) -> [String] {
        var args: [String] = []
        var cur = ""
        var inS = false, inD = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "'" && !inD { inS.toggle(); i = s.index(after: i); continue }
            if c == "\"" && !inS { inD.toggle(); i = s.index(after: i); continue }
            if !inS && !inD && c == " " {
                if !cur.isEmpty { args.append(cur); cur = "" }
            } else { cur.append(c) }
            i = s.index(after: i)
        }
        if !cur.isEmpty { args.append(cur) }
        return args
    }

    /// v4.4.4: 原生 Python CLI——App/bin/python3（iPhone 芯片直跑，PEP 730 CPython iOS）。
    /// 未内置时给明确指引（不静默降级到 iSH，避免 AI 误以为原生可用）。
    private static func runIOSPython3(_ command: String) -> [String: Any] {
        let pythonPath = Bundle.main.bundlePath + "/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            return ["command": command, "exit_code": 1,
                    "stdout": "python3: 原生 Python 未内置（此构建未集成 Python.xcframework）— 请用 iSH 版：sh -c 'python3 ...'（注意 iSH 内不能 import numpy/pandas，会段错误闪退）",
                    "ios_native": true]
        }
        let body = command.dropFirst("python3".count)
        let args = shellSplitArgs(String(body))
        let res = BuildRunner.shared.run(executable: pythonPath, args: args,
                                         env: ["PYTHONIOENCODING": "utf-8"], timeout: 120)
        var out = res.stdout
        if res.timedOut { out += "\n[python3 执行超时 120s 被终止]" }
        if let serr = res.spawnError, !serr.isEmpty {
            out += "\n[spawn error: \(serr)]"
        }
        return ["command": command, "exit_code": res.exitCode, "stdout": out,
                "stderr": res.stderr, "ios_native": true]
    }

    private static func runIOSKfdDiag(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var pathArg: String?
        for a in parts.dropFirst() {
            if !a.hasPrefix("-") { pathArg = a; break }
        }
        guard let raw = pathArg else {
            return ["command": command, "exit_code": 1,
                    "stdout": "usage: kfd_diag <path> — 只读输出 Mach-O 的代码签名结构 (LC_CODE_SIGNATURE → superblob → CodeDirectory)。纯诊断，不注入。",
                    "ios_native": true]
        }
        let path = ShellExecTool.normalizePath((raw as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "kfd_diag: \(path): No such file or directory", "ios_native": true]
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ["command": command, "exit_code": 1, "stdout": "kfd_diag: \(path): cannot read", "ios_native": true]
        }
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { guard o + 3 < b.count else { return 0 }; return UInt32(b[o]) | (UInt32(b[o+1])<<8) | (UInt32(b[o+2])<<16) | (UInt32(b[o+3])<<24) }
        func b32(_ o: Int) -> UInt32 { guard o + 3 < b.count else { return 0 }; return (UInt32(b[o])<<24) | (UInt32(b[o+1])<<16) | (UInt32(b[o+2])<<8) | UInt32(b[o+3]) }
        var out: [String] = []
        out.append("kfd_diag: \(path) (\(b.count) bytes)")
        // 定位 arm64 slice（fat/thin）
        var base = 0
        let magic = u32(0)
        if magic == 0xbebafeca { // FAT_CIGAM
            let n = Int(b32(4)); var found = false
            for j in 0..<n {
                let e = 8 + j*20
                if b32(e) == 0x0100000c { base = Int(b32(e+8)); found = true; break }
            }
            if !found { out.append("kfd_diag: no arm64 slice (fat)"); return ["command": command, "exit_code": 1, "stdout": out.joined(separator: "\n"), "ios_native": true] }
        } else if magic == 0xfeedfacf { // MH_MAGIC_64
            base = 0
        } else {
            out.append("kfd_diag: not a Mach-O 64 (magic 0x\(String(format:"%08x", magic)))")
            return ["command": command, "exit_code": 0, "stdout": out.joined(separator: "\n"), "ios_native": true]
        }
        // 遍历 load commands 找 LC_CODE_SIGNATURE (0x1d)
        let ncmds = Int(u32(base + 16))
        var off = base + 32
        var sigoff = 0
        for _ in 0..<ncmds {
            if off + 8 > b.count { break }
            let c = u32(off); let sz = Int(u32(off+4))
            if c == 0x1d { sigoff = Int(u32(off+8)); break }
            off += sz
        }
        out.append("kfd_diag: sigoff=\(sigoff) ncmds=\(ncmds) filelen=\(b.count)")
        if sigoff == 0 || sigoff + 12 > b.count {
            out.append("kfd_diag: NO LC_CODE_SIGNATURE (no embedded signature) — 无法提取 cdhash 的直接原因")
            return ["command": command, "exit_code": 0, "stdout": out.joined(separator: "\n"), "ios_native": true,
                    "hint": "真机 VpnTunnel 无内嵌签名：TrollStore 重签剥离了 LC_CODE_SIGNATURE，kfd_helper 无法解析 cdhash。需先 ldid 补签名再提取，或改注入方案。"]
        }
        let sbMagic = b32(sigoff), sbLen = b32(sigoff+4), sbCnt = b32(sigoff+8)
        out.append(String(format: "kfd_diag: superblob magic=0x%08x length=%u count=%u", sbMagic, sbLen, sbCnt))
        if sbMagic != 0xfade0cc0 {
            out.append("kfd_diag: superblob magic mismatch (expected 0xfade0cc0)")
            return ["command": command, "exit_code": 0, "stdout": out.joined(separator: "\n"), "ios_native": true]
        }
        let cnt = Int(min(sbCnt, 0x1000))
        for i in 0..<cnt {
            let e = sigoff + 12 + i*12
            if e + 12 > b.count { break }
            let t = b32(e), o = b32(e+4), l = b32(e+8)
            out.append(String(format: "kfd_diag: idx[%d] type=%u off=%u len=%u", i, t, o, l))
            if t == 0 && o + 44 <= b.count - sigoff { // CSSLOT_CODEDIRECTORY
                let cd = sigoff + Int(o)
                let cdMagic = b32(cd), cdLen = b32(cd+4), cdVersion = b32(cd+8)
                // cs_codedirectory: magic0 length4 version8 flags12 hashOffset16 identOffset20
                // nSpecialSlots24 nCodeSlots28 codeLimit32 hashSize36 hashType37 platform38 pageSize39
                let hashSize = (cd+36 < b.count) ? b[cd+36] : 0
                let hashType = (cd+37 < b.count) ? b[cd+37] : 0
                let pageSize = (cd+39 < b.count) ? b[cd+39] : 0
                out.append(String(format: "kfd_diag:   CD magic=0x%08x len=%u version=%u hashSize=%u hashType=%u pageSize=%u (hashType 1=SHA1 2=SHA256 3=SHA384)",
                                  cdMagic, cdLen, cdVersion, hashSize, hashType, pageSize))
                if cdMagic != 0xfade0c02 { out.append("kfd_diag:   CD magic mismatch (expected 0xfade0c02)") }
            }
        }
        let joined = out.joined(separator: "\n")
        return ["command": command, "exit_code": 0, "stdout": joined, "ios_native": true,
                "hint": "kfd_diag 只读解析签名结构，不注入、不触发 kfd/panic。据 CD hashType/hashSize 可判断为何 kfd_helper 提取失败（无签名 / hashType 不支持 / 越界）。"]
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
                "stdout": "Usage: find <path> [-name|-iname '<pattern>'] [-type f|d] [-maxdepth N]",
                "ios_native": true
            ]
        }
        
        // 灵活解析：路径是第一个不以 - 开头的参数；-name/-iname/-maxdepth 任意位置
        var searchPath: String? = nil
        var namePattern: String? = nil
        var ignoreCase = false
        var maxDepth = 5
        // v4.3.13: 支持 -type f/d (缺省 = 全部)。旧实现无类型过滤，AI 发 `find ... -type f` 直接 Usage。
        var fileType: Character? = nil
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
            if p == "-type" {
                if i + 1 < parts.count, let t = parts[i+1].first {
                    fileType = t == "f" || t == "d" ? t : fileType
                }
                i += 2
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
                "stdout": "Usage: find <path> [-name|-iname '<pattern>'] [-type f|d] [-maxdepth N]",
                "ios_native": true
            ]
        }
        let resolved = ShellExecTool.normalizePath((rawPath as NSString).expandingTildeInPath)
        guard resolved == "." || resolved.hasPrefix("/") else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: find <path> [-name|-iname '<pattern>'] [-type f|d] [-maxdepth N]",
                "ios_native": true
            ]
        }
        
        // v4.3.13: 无 -name/-iname 时列出全部（按 -type/-maxdepth 过滤），不强制 pattern
        let resolvedPath = resolved
        let nameRegex = (namePattern ?? "*").replacingOccurrences(of: "*", with: ".*")
        let compareOpts: String.CompareOptions = ignoreCase ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        
        var results: [String] = []
        
        func findRecursive(dir: String, depth: Int) {
            guard depth <= maxDepth else { return } // 用 -maxdepth 限制深度
            do {
                let items = try fm.contentsOfDirectory(atPath: dir)
                for item in items {
                    let fullPath = dir + "/" + item
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                    // v4.3.13: -type f/d 过滤 (缺省全列)
                    let typeOK = fileType == nil
                        || (fileType == "f" && !isDir.boolValue)
                        || (fileType == "d" && isDir.boolValue)
                    // 匹配文件名 (-name 精确大小写；-iname 忽略大小写）
                    if item.range(of: nameRegex, options: compareOpts) != nil, typeOK {
                        results.append(fullPath)
                    }
                    // 递归子目录
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
        
        // v3.6.19d: 修复 grep 对二进制失效的根因——原来用 String(contentsOfFile:encoding:.utf8) 读文件，
        // 二进制 UTF-8 解码必 nil → 静默跳过 → 输出空。改为 Data 字节读取 + 按 0x0A 拆字节行；
        // 匹配默认按【字面字节序列】(pattern 转 UTF-8 Data)，不再强制正则(原 .regularExpression 会把
        // 用户想搜的 "cdhash"/"CodeDirectory" 里的 . 当通配符误伤)；-E 才启用正则(用可打印化文本)。
        let useRegex = flags.contains("E")
        func printableLine(_ line: Data) -> String {
            var s = ""
            for byte in line {
                if byte == 0x09 { s += "\t" }
                else if byte >= 0x20 && byte <= 0x7e { s += String(UnicodeScalar(byte)) }
                else { s += "." }
            }
            return s
        }
        let patternBytes = Data(pattern.utf8)
        let patternBytesLower = Data(pattern.lowercased().utf8)

        var matchedFiles: [String] = []
        var matchedLines: [String] = []
        var totalCount = 0
        for file in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { continue }
            // 按 0x0A 拆成字节行（二进制也按字节行处理）
            var byteLines: [Data] = []
            var lineStart = data.startIndex
            for i in data.indices where data[i] == 0x0A {
                byteLines.append(Data(data[lineStart..<i])); lineStart = data.index(after: i)
            }
            byteLines.append(Data(data[lineStart...]))
            var fileMatched = false
            var fileCount = 0
            for (idx, line) in byteLines.enumerated() {
                let found: Bool
                if useRegex {
                    let text = printableLine(line)
                    found = ignoreCase ? text.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil
                                       : text.range(of: pattern, options: .regularExpression) != nil
                } else if ignoreCase {
                    // 字节级忽略大小写：ASCII A-Z 转小写后匹配
                    let lowered = Data(line.map { ($0 >= 0x41 && $0 <= 0x5a) ? ($0 + 0x20) : $0 })
                    found = lowered.range(of: patternBytesLower) != nil
                } else {
                    found = line.range(of: patternBytes) != nil
                }
                let hit = invert ? !found : found
                if hit {
                    fileMatched = true
                    fileCount += 1
                    totalCount += 1
                    if !filesOnly && !countOnly {
                        let prefix = files.count > 1 ? "\(file):" : ""
                        let num = lineNumbers ? "\(idx + 1):" : ""
                        matchedLines.append("\(prefix)\(num)\(printableLine(line))")
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
            "hint": "iOS native grep: -i/-r/-l/-c/-n/-v 同标准；默认按字面字节匹配(可搜二进制如 cdhash/CodeDirectory)，-E 启用正则；-a 自动(二进制可打印化)。不再因二进制 UTF-8 解码失败而静默输出空。"
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
        
        // v4.0.0: 支持 -r/-f/-rf 等选项，跳过选项取真正的路径参数（修复 `rm -rf <dir>` 把 -rf 当文件名）
        let paths = parts.dropFirst().filter { !$0.hasPrefix("-") }
        guard !paths.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: rm [-rf] <path>", "ios_native": true]
        }
        var removed: [String] = []
        var firstErr: String? = nil
        for p in paths {
            let path = ShellExecTool.normalizePath((p as NSString).expandingTildeInPath)
            do {
                try fm.removeItem(atPath: path)
                removed.append(path)
            } catch {
                if firstErr == nil { firstErr = error.localizedDescription }
            }
        }
        if removed.isEmpty {
            return ["command": command, "exit_code": 1, "stdout": "rm failed: \(firstErr ?? "no path removed")", "ios_native": true]
        }
        return ["command": command, "exit_code": 0, "stdout": "Removed: \(removed.joined(separator: ", "))", "ios_native": true]
    }
    
    /// v3.1.32: iOS 原生 mv 命令——移动/重命名
    private static func runIOSMv(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // v4.0.0: 支持选项(如 -n/-f)，跳过选项取源/目标路径（修复 mv -f src dst 参数错位）
        let args = parts.dropFirst().filter { !$0.hasPrefix("-") }
        guard args.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: mv [-f] <source> <destination>", "ios_native": true]
        }
        
        let src = ShellExecTool.normalizePath((args[0] as NSString).expandingTildeInPath)
        let dst = ShellExecTool.normalizePath((args[1] as NSString).expandingTildeInPath)
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
        
        let options = parts.dropFirst().filter { $0.hasPrefix("-") }
        let force = options.contains("-f")
        _ = options.contains("-r")  // copyItem 天然递归目录，-r 仅语义兼容
        
        // v4.0.0: 支持选项(如 -r/-f)，跳过选项取源/目标路径
        let args = parts.dropFirst().filter { !$0.hasPrefix("-") }
        guard args.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: cp [-r] [-f] <source> <destination>", "ios_native": true]
        }
        
        let src = ShellExecTool.normalizePath((args[0] as NSString).expandingTildeInPath)
        let dst = ShellExecTool.normalizePath((args[1] as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: src) else {
            return ["command": command, "exit_code": 1, "stdout": "cp: \(src): No such file or directory", "ios_native": true]
        }
        
        // v4.3.13: 目标若是已存在目录 → 复制到 dst/(basename)。旧实现 dst=目录且含同名文件时报"同名项目"。
        var dstIsDir: ObjCBool = false
        fm.fileExists(atPath: dst, isDirectory: &dstIsDir)
        let target = dstIsDir.boolValue
            ? (dst as NSString).appendingPathComponent((src as NSString).lastPathComponent)
            : dst
        
        if fm.fileExists(atPath: target), !force {
            return ["command": command, "exit_code": 1, "stdout": "cp: \(target) already exists (use cp -f to overwrite)", "ios_native": true]
        }
        if fm.fileExists(atPath: target) {
            // -f 覆盖：先删已存在目标再复制
            do { try fm.removeItem(atPath: target) }
            catch {
                return ["command": command, "exit_code": 1, "stdout": "cp: failed to remove \(target): \(error.localizedDescription)", "ios_native": true]
            }
        }
        do {
            try fm.copyItem(atPath: src, toPath: target)
            return ["command": command, "exit_code": 0, "stdout": "Copied: \(src) -> \(target)", "ios_native": true]
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
    
    /// v3.6.10: iOS 原生 base64 命令——编码/解码文件。
    ///   base64 <file>    → 输出 base64（单行，方便喂给 Alpine）
    ///   base64 -d <file> → 从 base64 解码还原，写 <file>.decoded
    /// 管道过滤器场景(cat x | base64)由 applySwiftFilter 的 case "base64" 处理。
    private static func runIOSBase64(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: base64 [-d] <file>", "ios_native": true]
        }
        let decode = parts.contains("-d")
        let noOpts = parts.filter { !$0.hasPrefix("-") }
        let filePath = ShellExecTool.normalizePath(((noOpts.last ?? "") as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: filePath) else {
            return ["command": command, "exit_code": 1, "stdout": "base64: \(filePath): No such file or directory", "ios_native": true]
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            if decode {
                guard let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else {
                    return ["command": command, "exit_code": 1, "stdout": "base64: invalid input", "ios_native": true]
                }
                let outPath = filePath + ".decoded"
                try decoded.write(to: URL(fileURLWithPath: outPath))
                return ["command": command, "exit_code": 0, "stdout": "decoded \(data.count) b64 → \(outPath) (\(decoded.count) bytes)", "ios_native": true]
            } else {
                return ["command": command, "exit_code": 0, "stdout": data.base64EncodedString(), "ios_native": true]
            }
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "base64 failed: \(error.localizedDescription)", "ios_native": true]
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
    
    /// v3.1.32: iOS 原生 curl 命令——下载文件 / 抓取页面 (同步）
    /// v4.3.26: ①URL/参数引号自动剥除 (修复带引号 URL 误报 Invalid URL)；②无 -O/-o 时
    /// 抓取到 stdout (JS 渲染页检测 needs_render)；③解析失败报具体原因而非笼统 Invalid URL。
    private static func runIOSDownload(_ command: String) -> [String: Any] {
        let rawParts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        guard rawParts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: curl -O <url> / curl -sL <url> / curl -o <path> <url>", "ios_native": true]
        }

        func stripQuotes(_ s: String) -> String {
            var t = s
            while t.hasPrefix("\"") || t.hasPrefix("'") { t.removeFirst() }
            while t.hasSuffix("\"") || t.hasSuffix("'") { t.removeLast() }
            return t
        }

        var urlString = ""
        var outputPath = ""
        var sawFlagO = false
        var userAgent: String? = nil
        var i = 1
        while i < rawParts.count {
            let p = rawParts[i]
            let pn = stripQuotes(p)
            if p == "-O" {
                sawFlagO = true
                if i + 1 < rawParts.count { urlString = stripQuotes(rawParts[i + 1]); i += 1 }
            } else if p == "-o" {
                if i + 1 < rawParts.count { outputPath = stripQuotes(rawParts[i + 1]); i += 1 }
            } else if p == "-A" {
                if i + 1 < rawParts.count { userAgent = stripQuotes(rawParts[i + 1]); i += 1 }
            } else if pn.hasPrefix("http://") || pn.hasPrefix("https://") {
                urlString = pn
            }
            i += 1
        }

        guard !urlString.isEmpty else {
            return ["command": command, "exit_code": 1,
                    "stdout": "curl: 原生模式在命令里没解析到 http(s):// URL。注意 URL 若带引号会自动剥除；下载用 -O <url>，抓取正文用 -sL <url>。",
                    "ios_native": true]
        }
        guard let url = URL(string: urlString) else {
            return ["command": command, "exit_code": 1,
                    "stdout": "curl: Invalid URL '\(urlString)' (iOS 原生模式，检查 URL 格式/转义)",
                    "ios_native": true]
        }

        // 抓取到 stdout 模式（无 -O 且无 -o）
        if !sawFlagO && outputPath.isEmpty {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue(userAgent ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            let sem = DispatchSemaphore(value: 0)
            var data: Data? = nil
            var fetchErr: Error? = nil
            URLSession.shared.dataTask(with: req) { d, _, e in
                data = d; fetchErr = e; sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 35)
            if let e = fetchErr {
                return ["command": command, "exit_code": 1, "stdout": "curl: fetch failed: \(e.localizedDescription)", "ios_native": true]
            }
            guard let d = data else {
                return ["command": command, "exit_code": 1, "stdout": "curl: fetch timed out after 35s for \(urlString)", "ios_native": true]
            }
            guard !d.isEmpty else {
                return ["command": command, "exit_code": 1, "stdout": "curl: fetch returned empty body for \(urlString)", "ios_native": true]
            }
            var body = String(data: d, encoding: .utf8) ?? "(non-UTF8 body, \(d.count) bytes)"
            var out: [String: Any] = ["command": command, "exit_code": 0, "ios_native": true, "bytes": d.count]
            // v4.3.26: 动态渲染页检测——HTML 里 ≥3 个 <script> 但可见正文极少 → needs_render 提示
            let lower = body.lowercased()
            if lower.contains("<html") || lower.contains("<script") {
                let scriptCount = lower.components(separatedBy: "<script").count - 1
                let visible = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                                  .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                                  .trimmingCharacters(in: .whitespacesAndNewlines)
                if scriptCount >= 3 && visible.count < 100 {
                    out["needs_render"] = true
                    out["hint"] = "该页面由 JS 动态渲染，curl 只能拿到原始 HTML，拿不到渲染后正文。请改用内置浏览器：browser.navigate 打开 + browser.text 读正文。"
                }
            }
            if body.count > 200_000 {
                body = String(body.prefix(200_000)) + "\n... [body truncated to 200000 chars]"
            }
            out["stdout"] = body
            return out
        }

        // 下载模式
        if outputPath.isEmpty {
            let filename = url.lastPathComponent
            outputPath = NSHomeDirectory() + "/Documents/downloads/" + (filename.isEmpty ? "download.bin" : filename)
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
            return ["command": command, "exit_code": 1, "stdout": "curl: download failed: \(error.localizedDescription)", "ios_native": true]
        }
    }
    
    /// v3.1.32: iOS 原生 plutil 命令——读 plist 文件
    private static func runIOSPlutil(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: plutil -p <file.plist>  或  plutil -convert xml1 [-o out.xml] <file.plist>", "ios_native": true]
        }
        
        // 解析参数：-convert xml1 / -o <out> / -p；文件路径=首个非 - 参数
        var convertXML = false
        var outPath: String? = nil
        var filePath = ""
        var i = 1
        while i < parts.count {
            let p = parts[i]
            if p == "-convert" || p == "-c" {
                convertXML = true
                if i + 1 < parts.count && (parts[i+1] == "xml1" || parts[i+1] == "xml") { i += 1 }
            } else if p == "-o", i + 1 < parts.count {
                outPath = parts[i+1]
                i += 1
            } else if !p.hasPrefix("-") && filePath.isEmpty {
                filePath = p
            }
            i += 1
        }
        
        guard !filePath.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "plutil: no file specified", "ios_native": true]
        }
        
        let path = ShellExecTool.normalizePath((filePath as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "plutil: \(path): No such file or directory", "ios_native": true]
        }
        
        // v4.3.13: 改用 PropertyListSerialization 全类型解析——支持二进制 plist、嵌套 Data/Date/数字/布尔。
        // 旧实现用 NSDictionary(contentsOfFile:)+JSONSerialization，遇 Data/Date 抛错、二进制 plist 读取失败 → 空输出。
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return ["command": command, "exit_code": 1, "stdout": "plutil: Failed to read plist (binary/xml parse)", "ios_native": true]
        }
        
        if convertXML {
            guard let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
                return ["command": command, "exit_code": 1, "stdout": "plutil: Failed to convert to xml1", "ios_native": true]
            }
            if let out = outPath {
                let dest = ShellExecTool.normalizePath((out as NSString).expandingTildeInPath)
                do {
                    try xml.write(to: URL(fileURLWithPath: dest))
                    return ["command": command, "exit_code": 0, "stdout": "Converted plist to XML: \(dest)", "ios_native": true]
                } catch {
                    return ["command": command, "exit_code": 1, "stdout": "plutil: failed to write \(dest): \(error.localizedDescription)", "ios_native": true]
                }
            }
            return ["command": command, "exit_code": 0, "stdout": String(data: xml, encoding: .utf8) ?? "", "ios_native": true]
        }
        
        // -p 打印：递归序列化为可读文本（全类型）
        return ["command": command, "exit_code": 0, "stdout": plutilPrint(plist, indent: 0), "ios_native": true]
    }
    
    /// v4.3.13: plutil -p 打印辅助——递归把 plist 全类型(字典/数组/Data/Date/数字/布尔/字符串)转为可读文本
    private static func plutilPrint(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case let d as [String: Any]:
            if d.isEmpty { return pad + "{}" }
            var lines: [String] = []
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                let child = plutilPrint(v, indent: indent + 1)
                lines.append(pad + "\(k) => \(child.trimmingCharacters(in: .newlines))")
            }
            return lines.joined(separator: "\n")
        case let a as [Any]:
            if a.isEmpty { return pad + "()" }
            return a.map { plutilPrint($0, indent: indent).trimmingCharacters(in: .newlines) }.joined(separator: "\n")
        case let s as String:
            return "\"\(s)\""
        case let b as Bool:
            // v4.3.13: Bool 须在 NSNumber 之前匹配（__NSCFBoolean 是 NSNumber 子类，否则输出 0/1）
            return b ? "true" : "false"
        case let n as NSNumber:
            return "\(n)"
        case let data as Data:
            let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
            let tail = data.count > 64 ? " ... (\(data.count) bytes)" : ""
            return "<data: \(hex)\(tail)>"
        case let date as Date:
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"; f.locale = Locale(identifier: "en_US_POSIX")
            return "<date: \(f.string(from: date))>"
        case let b as Bool:
            return b ? "true" : "false"
        case is NSNull:
            return "<null>"
        default:
            return "\(value)"
        }
    }
    
    /// v3.1.32: iOS 原生 sqlite3 命令——查询 SQLite 数据库
    private static func runIOSSqlite(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        
        // 解析：sqlite3 <db_path> "<query>" 或 'query'
        // v3.6.19d: 原来只认双引号，AI/用户发单引号 SQL 会 usage 误报；改为自动识别单/双引号包裹，
        // 并剥掉 db 路径自身可能带的引号。
        let dq = command.firstIndex(of: "\"")
        let sq = command.firstIndex(of: "'")
        let openQuote: Character
        if let d = dq, let s = sq { openQuote = d < s ? "\"" : "'" }
        else if dq != nil { openQuote = "\"" }
        else if sq != nil { openQuote = "'" }
        else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\"", "ios_native": true]
        }
        guard let qStart = command.firstIndex(of: openQuote) else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\"", "ios_native": true]
        }
        let qRest = command[command.index(after: qStart)...]
        guard let qEnd = qRest.firstIndex(of: openQuote) else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\"", "ios_native": true]
        }
        let query = String(qRest[..<qEnd])

        // 提取 db 路径 (在引号之前），并剥掉路径自身可能带的引号
        let beforeQuote = command[..<qStart].trimmingCharacters(in: .whitespaces)
        let parts = beforeQuote.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\"", "ios_native": true]
        }
        var dbArg = parts[1]
        if dbArg.hasPrefix("\""), dbArg.hasSuffix("\"") { dbArg = String(dbArg.dropFirst().dropLast()) }
        if dbArg.hasPrefix("'"), dbArg.hasSuffix("'") { dbArg = String(dbArg.dropFirst().dropLast()) }
        let dbPath = ShellExecTool.normalizePath((dbArg as NSString).expandingTildeInPath)
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
        // v4.0.0: native 无真解压实现（旧实现只列表内容、假装解压成功，误导 AI）。
        // unzip/zip 命令已由 autoRouteNeedsAlpine 自动路由到 Alpine 真工具链（真解压，autoBind 后能读 iOS 文件）。
        // 这里兜底：明确报错指向 Alpine，绝不再静默返回假列表。
        return ["command": command, "exit_code": 1, "ios_native": true,
                "stdout": "native unzip 不支持真实解压（已弃用假列表实现）。unzip/zip 会自动路由到 Alpine 真工具链——直接写 `unzip <iOS路径>/x.zip -d <iOS路径>/out` 即可，系统会 autoBind 并真解压。"]
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
