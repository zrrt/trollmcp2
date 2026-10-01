import Foundation

/// iSH-ARM64 引擎 —— v4.3.57 测试版：CISH（libish 静态库）已从主进程移除。
///
/// 背景：TrollMCP2 分享面板 SIGSEGV（MobileIcons LICreateIconForImages → CoreImage）
/// 从早期版本起持续复现，与所有 App 内代码/声明改动无关。TrollFools（无 libish）
/// 分享正常。libish 是 iSH-ARM64 模拟器静态库，其全局初始化可能在进程启动时
/// 污染内存/信号/线程状态，干扰系统框架的图标生成。本桩版用于验证该假设：
/// 若移除 CISH 后分享恢复正常 → 根因确认，随后将 ish 工具改造为独立进程方案。
///
/// 本桩保留全部公开 API 签名（调用方无需改动即可编译），所有操作返回"不可用"。
enum ISHEngine {
    enum BootState {
        case idle, booting, booted, failed(String)
    }

    private static let lock = NSLock()
    private static var state: BootState = .idle

    static var autoBindEnabled = true

    static var isBooted: Bool { false }
    static var cwd: String { "/root" }

    static func resetCwd() {
        lock.lock()
        defer { lock.unlock() }
    }

    static func bindMount(_ linuxPath: String, _ hostPath: String, readOnly: Bool) -> Int32 {
        return -1000
    }

    static func bindUnmount(_ linuxPath: String) -> Int32 {
        return -1000
    }

    static func bindAppContainer(bundleId: String, readOnly: Bool = true)
        -> (ok: Bool, mountPath: String?, hostPath: String?, backupPath: String?, error: String?) {
        return (false, nil, nil, nil, "ish 内核未编译（v4.3.57 测试版）")
    }

    static func autoBind(_ command: String) -> String {
        return command
    }

    static func ensureDNS() {
    }

    static func ensureBooted() -> String? {
        return "[ish 内核未编译（v4.3.57 测试版）]"
    }

    static func exec(_ command: String, timeout: TimeInterval)
        -> (output: String, exitCode: Int32, timedOut: Bool) {
        return ("[ish 内核未编译（v4.3.57 测试版）：此版本用于验证分享崩溃根因，Alpine 工具不可用]", -1, false)
    }

    static func missingToolPkg(_ output: String) -> String? {
        return nil
    }
}
