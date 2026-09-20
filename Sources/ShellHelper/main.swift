import Foundation
import Darwin

// ShellHelper：独立进程执行 ios_system 命令（v3.0.35）
// 背景：ios_system 命令在进程内执行，一旦命令阻塞（如访问 iOS 16 上会挂死的
// App bundle 路径、无限循环），会把整个 App 卡死、无法恢复。
// 方案：主 App 用 posix_spawn 拉起本 helper 执行命令，超时直接 SIGKILL 进程组，
// 保证主进程永远不被卡死命令拖垮。
//
// 用法：shellhelper <cwd> <command> <appDir>
//   - chdir 到 <cwd> 并设置 ios_system 逻辑 PWD
//   - 加载 <appDir>/ios_system.framework/ios_system 执行 <command>
//   - 完成后向 fd 3 写报告：EXIT:<code>\nCWD:<finalCwd>\n，然后 _exit(code)
// 输出（stdout+stderr 合并）由父进程通过管道捕获。

func writeReport(exit: Int32, cwd: String) {
    let s = "EXIT:\(exit)\nCWD:\(cwd)\n"
    s.withCString { p in
        _ = write(3, p, strlen(p))
    }
}

let args = CommandLine.arguments
guard args.count >= 4 else { _exit(2) }
let cwdArg = args[1]
let command = args[2]
let appDir = args[3]

if chdir(cwdArg) != 0 {
    writeReport(exit: 3, cwd: cwdArg)
    _exit(3)
}

let fwPath = appDir + "/ios_system.framework/ios_system"
guard let h = dlopen(fwPath, RTLD_NOW) else {
    writeReport(exit: 4, cwd: cwdArg)
    _exit(4)
}

if let envPtr = dlsym(h, "initializeEnvironment") {
    typealias EnvFn = @convention(c) () -> Void
    unsafeBitCast(envPtr, to: EnvFn.self)()
}

guard let fnPtr = dlsym(h, "ios_system") else {
    writeReport(exit: 5, cwd: cwdArg)
    _exit(5)
}
typealias IosSystemFn = @convention(c) (UnsafePointer<CChar>) -> Int32
let execFn = unsafeBitCast(fnPtr, to: IosSystemFn.self)

// 设置逻辑 PWD，保证相对路径按 cwdArg 解析
let escaped = cwdArg.replacingOccurrences(of: "'", with: "'\\''")
let cdCmd = "cd '" + escaped + "'"
_ = cdCmd.withCString { execFn($0) }

// 执行用户命令
let code = command.withCString { execFn($0) }

// 报告最终工作目录（支持命令内 cd 跨调用保留）
var buf = [CChar](repeating: 0, count: 4096)
var cwdFinal = cwdArg
if getcwd(&buf, 4096) != nil {
    cwdFinal = String(cString: buf)
}
writeReport(exit: code, cwd: cwdFinal)
_exit(code)
