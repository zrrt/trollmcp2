import Foundation
import SwiftUI
import Darwin

/// v2.9.145c：崩溃日志捕获——闪退自动落盘到工作区 crash/，设置页「崩溃日志」可查看。
/// 解决"闪退原因不可见"的排障盲区：此前用户报闪退只能靠猜，加上这个后每次闪退都有现场留痕。
enum CrashCatcher {
    static var crashDir: URL {
        Workspace.root.appendingPathComponent("crash", isDirectory: true)
    }

    // v2.9.150：signal-safe 预分配缓冲（install() 时在正常上下文分配，
    // handler 内只做指针写入，绝不触发 Swift 堆分配/字符串/ObjC）
    private static var sigPathBuf: UnsafeMutablePointer<CChar>?
    private static var sigMsgBuf: UnsafeMutablePointer<CChar>?
    private static let sigPathCap = 1024
    private static let sigMsgCap = 128

    static func install() {
        // 预分配信号缓冲（正常上下文，避免 handler 内 Swift 运行时分配二次崩溃）
        if sigPathBuf == nil { sigPathBuf = .allocate(capacity: sigPathCap) }
        if sigMsgBuf == nil { sigMsgBuf = .allocate(capacity: sigMsgCap) }

        // 1) ObjC 未捕获异常（Swift fatalError / 强解包 / 数组越界等走这里）
        NSSetUncaughtExceptionHandler { exception in
            let ts = time(nil)
            let dir = CrashCatcher.crashDir.path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var lines: [String] = [
                "=== Uncaught Exception @ \(ts) ===",
                "name: \(exception.name.rawValue)",
                "reason: \(exception.reason ?? "(nil)")",
                "userInfo: \(exception.userInfo ?? [:])",
                "--- callStackSymbols ---"
            ]
            lines += exception.callStackSymbols
            let path = "\(dir)/exc_\(ts).txt"
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }

        // 2) POSIX 信号（EXC_BAD_ACCESS 等内存错误走这里）——handler 只做 signal-safe 的最小写盘
        func arm(_ sig: Int32) {
            signal(sig) { s in
                CrashCatcher.writeSignal(s)
            }
        }
        arm(SIGABRT)
        arm(SIGSEGV)
        arm(SIGBUS)
        arm(SIGILL)
        arm(SIGTRAP)
        arm(SIGFPE)
    }

    /// v2.9.150：纯 signal-safe 写盘——上一版用 Swift String 插值/Date/数组，
    /// 在信号上下文里二次崩溃，导致 16 条日志全部只记录到 writeSignal 自身、
    /// 真正崩溃点被掩盖。现在只用 C 函数：
    ///   time/mkdir/open/snprintf/write/strlen/backtrace/backtrace_symbols_fd/close
    /// 全部 async-signal-safe。
    private static func writeSignal(_ s: Int32) {
        let ts = time(nil)
        let dir = crashDir.path
        _ = mkdir(dir, 0o755)
        let dc = (dir as NSString).utf8String
        guard let d = dc, let pb = sigPathBuf, let mb = sigMsgBuf else { return }
        snprintf(pb, sigPathCap, "%s/sig_%ld.txt", d, ts)
        let fd = open(pb, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        // 信号名用 strsignal（返回静态字符串，signal-safe）；fallback 打印数字
        let name = strsignal(s) ?? "SIG"
        snprintf(mb, sigMsgCap, "signal %s @ %ld\n", name, ts)
        _ = write(fd, mb, strlen(mb))
        // backtrace/backtrace_symbols_fd 均为 async-signal-safe
        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
        let n = backtrace(frames, 64)
        backtrace_symbols_fd(frames, n, fd)
        frames.deallocate()
        close(fd)
        // 恢复默认处理并重发，让系统也生成官方崩溃报告
        signal(s, SIG_DFL)
        raise(s)
    }

    // MARK: - 崩溃日志列表（设置页入口）

    static func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: crashDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        // 显式 sorted(by:) 避免 iOS16 SDK 的 SortComparator 重载歧义
        let urls: [URL] = entries.filter { $0.pathExtension == "txt" }
        let sortedUrls: [URL] = urls.sorted(by: { l, r in
            let lv = try? l.resourceValues(forKeys: [.contentModificationDateKey])
            let rv = try? r.resourceValues(forKeys: [.contentModificationDateKey])
            return (lv?.contentModificationDate ?? Date.distantPast) > (rv?.contentModificationDate ?? Date.distantPast)
        })
        return sortedUrls.map { $0.path }
    }

    static func content(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(读取失败)"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: crashDir)
    }
}

/// 崩溃日志查看页
struct CrashLogView: View {
    @State private var paths: [String] = []
    @State private var selected: String?
    @State private var content = ""
    @State private var toast: String?

    var body: some View {
        List {
            if paths.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                            .foregroundColor(.green)
                        Text("暂无崩溃记录")
                            .font(.footnote)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section(header: Text("共 \(paths.count) 条，按时间倒序")) {
                    ForEach(paths, id: \.self) { p in
                        Button {
                            content = CrashCatcher.content(p)
                            selected = p
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: p).lastPathComponent)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(CrashCatcher.content(p))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(6)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("崩溃日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { paths = CrashCatcher.list() }
        .sheet(item: $selected) { _ in
            NavigationView {
                ScrollView {
                    Text(content)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("崩溃详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { selected = nil }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") {
                    CrashCatcher.clear()
                    paths = []
                    toast = "已清空"
                }
                .disabled(paths.isEmpty)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toast = nil }
                    }
            }
        }
    }
}

extension String: Identifiable {
    public var id: String { self }
}
