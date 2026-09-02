import Foundation

// MARK: - 开发者指令存储（v2.9.19）
// 用户可自建多份开发者指令（KnowledgeBase/DeveloperInstructions/*.md），
// 每份可独立启用/停用，选择一份为"默认指令"注入 AI 请求。
// 元数据（启用状态/默认选择）存 UserDefaults；内容存 md 文件，便于外部编辑/备份。

final class DeveloperInstructionStore {
    static let shared = DeveloperInstructionStore()
    private init() {
        seedIfEmpty()
    }

    private struct Meta: Codable {
        var enabled: [String: Bool] = [:]   // 文件名 -> 是否启用
        var defaultName: String?            // 默认指令文件名
    }

    private var metaKey = "trollmcp2.dev_instructions_meta"

    private var dir: URL {
        let kb = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase")
        return kb.appendingPathComponent("DeveloperInstructions", isDirectory: true)
    }

    // MARK: 元数据

    private var meta: Meta {
        get {
            guard let data = UserDefaults.standard.data(forKey: metaKey),
                  let m = try? JSONDecoder().decode(Meta.self, from: data) else { return Meta() }
            return m
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: metaKey)
            }
        }
    }

    // MARK: 对外接口

    struct Item: Identifiable, Equatable {
        var id: String { name }
        let name: String          // 去掉 .md 的文件名
        let content: String
        var enabled: Bool
        var isDefault: Bool
    }

    func list() -> [Item] {
        let m = meta
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Item(name: name, content: content,
                            enabled: m.enabled[name] ?? true,
                            isDefault: m.defaultName == name)
            }
    }

    func create(name: String, content: String) {
        let safe = sanitize(name)
        guard !safe.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe).appendingPathExtension("md")
        try? content.data(using: .utf8)?.write(to: url)
        if meta.defaultName == nil { meta.defaultName = safe }
        AuditLog.shared.log("dev_instructions", detail: "新建 \(safe)")
    }

    func update(name: String, content: String) {
        let safe = sanitize(name)
        guard !safe.isEmpty else { return }
        let url = dir.appendingPathComponent(safe).appendingPathExtension("md")
        try? content.data(using: .utf8)?.write(to: url)
        AuditLog.shared.log("dev_instructions", detail: "更新 \(safe)")
    }

    func delete(name: String) {
        let safe = sanitize(name)
        let url = dir.appendingPathComponent(safe).appendingPathExtension("md")
        try? FileManager.default.removeItem(at: url)
        var m = meta
        m.enabled.removeValue(forKey: safe)
        if m.defaultName == safe { m.defaultName = nil }
        meta = m
        AuditLog.shared.log("dev_instructions", detail: "删除 \(safe)")
    }

    func setEnabled(name: String, enabled: Bool) {
        let safe = sanitize(name)
        var m = meta
        if enabled { m.enabled.removeValue(forKey: safe) } else { m.enabled[safe] = false }
        meta = m
    }

    func setDefault(name: String) {
        let safe = sanitize(name)
        var m = meta
        m.defaultName = safe
        m.enabled[safe] = true
        meta = m
        AuditLog.shared.log("dev_instructions", detail: "设默认 \(safe)")
    }

    /// 默认启用指令的内容（注入 AI 请求用）。无默认返回 nil。
    func defaultInjectionContent() -> String? {
        guard let def = meta.defaultName else { return nil }
        let m = meta
        if m.enabled[def] == false { return nil }
        let url = dir.appendingPathComponent(def).appendingPathExtension("md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: 内置种子

    private func seedIfEmpty() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              !files.contains(where: { $0.pathExtension.lowercased() == "md" }) else { return }
        // 首次使用：把内置默认指令复制进来
        let bundleURLs = [
            Bundle.main.url(forResource: "TrollMCPDeveloperInstructions", withExtension: "md"),
            Bundle.main.url(forResource: "TrollMCPDeveloperInstructions", withExtension: "md", subdirectory: "bin"),
        ]
        var seeded = false
        for url in bundleURLs {
            if let url = url, let text = try? String(contentsOf: url, encoding: .utf8) {
                let dst = dir.appendingPathComponent("TrollMCP默认开发者指令").appendingPathExtension("md")
                try? text.data(using: .utf8)?.write(to: dst)
                meta.defaultName = "TrollMCP默认开发者指令"
                seeded = true
                break
            }
        }
        if !seeded {
            let fallback = "# TrollMCP2 开发者指令\n\n在此编写你的开发者指令。\n"
            let dst = dir.appendingPathComponent("我的开发者指令").appendingPathExtension("md")
            try? fallback.data(using: .utf8)?.write(to: dst)
            meta.defaultName = "我的开发者指令"
        }
        AuditLog.shared.log("dev_instructions", detail: "已播种默认指令")
    }

    private func sanitize(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: disallowed).joined(separator: "")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "指令" : trimmed
    }
}
