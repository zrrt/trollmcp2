import Foundation
import Combine

/// v4.3.75：安装进度注册表。
/// ISHEngine 串行执行（lock 串行化），同一时刻最多一个活动安装任务——所以全局只挂一个进度。
/// apkAdd/exec 后台读线程逐行回调 → appendLine 解析 apk 输出（阶段 + (N/M) 包数 + 最近行）；
/// SwiftUI 侧 @ObservedObject 观察本单例，在"执行中"气泡实时渲染进度条，不再只有"执行中…"。
final class InstallationRegistry: ObservableObject {
    static let shared = InstallationRegistry()

    struct InstallProgress {
        let key: String            // 展示用："python3 py3-pip"
        let startedAt: Date
        var phase: String          // 准备环境 / 下载索引 / 安装包 / 完成 / 失败
        var done: Int = 0          // 已安装包数（从 apk 输出 (N/M) 解析）
        var total: Int = 0         // 总包数
        var lastLine: String = ""  // 最近一行（限 60 字符）
        var ok: Bool? = nil        // nil=进行中
        var summary: String = ""

        var fraction: Double {
            total > 0 ? min(1, Double(done) / Double(total)) : 0
        }
        var progressText: String {
            if total > 0 { return "\(phase) \(done)/\(total)" }
            return phase
        }
    }

    @Published private(set) var active: InstallProgress?

    /// 开始安装任务（串行引擎下不存在并发，直接覆盖）
    func start(key: String) {
        active = InstallProgress(key: key, startedAt: Date(), phase: "准备环境")
    }

    /// 后台读线程回调：逐行解析 apk 输出，提取阶段与 (N/M) 包数。
    /// @Published 跨线程更新不安全，统一切主线程。
    func appendLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var p = active, !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("WARNING:") || trimmed.hasPrefix("ERROR:") || trimmed.hasPrefix("fetch ") {
            // 噪声/告警行不打断阶段，仅记录最近行
        }
        // apk 输出形如 "(1/16) Installing openblas" / "(2/16) Installing ..."
        if let match = trimmed.range(of: #"\((\d+)/(\d+)\)"#, options: .regularExpression),
           let rg = trimmed[match].split(separator: "/").first?.trimmingCharacters(in: CharacterSet(charactersIn: "() ")),
           let rd = Int(rg) {
            p.done = rd
        }
        if trimmed.contains("Installing") || trimmed.contains("installing") {
            p.phase = "安装包"
        } else if trimmed.contains("Downloading") || trimmed.hasPrefix("fetch ") {
            p.phase = "下载索引"
        } else if trimmed.contains("Extracting") || trimmed.contains("extracting") {
            p.phase = "解包"
        }
        p.lastLine = String(trimmed.prefix(60))

        let snap = p
        DispatchQueue.main.async { [weak self] in
            if self?.active?.key == snap.key {
                self?.active = snap
            }
        }
    }

    /// 安装结束（成功/失败）。summary 为结构化诊断或安装结果。
    func finish(ok: Bool, summary: String) {
        guard var p = active else { return }
        p.ok = ok
        p.phase = ok ? "完成" : "失败"
        p.summary = summary
        let snap = p
        DispatchQueue.main.async { [weak self] in
            self?.active = snap
        }
    }

    /// 收起进度（结果气泡已折叠展示后清空，避免旧进度残留）
    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.active = nil
        }
    }
}
