import Foundation

// MARK: - 技能存储（v2.9.17）
// 让技能从"只显示在列表里的摆设"变成"AI 可发现、可读取、可启用"的真实能力。
// 存储位置：KnowledgeBase/skills.json
// 启用状态：UserDefaults "trollmcp2.skills_enabled"

struct SkillItem: Identifiable, Equatable {
    var id = UUID()
    let name: String
    let summary: String      // 摘要：AI 判断何时使用该技能的依据
    let instruction: String  // 完整指令：AI 按此执行

    var dict: [String: String] { ["name": name, "summary": summary, "instruction": instruction] }

    init(name: String, summary: String, instruction: String) {
        self.name = name
        self.summary = summary
        self.instruction = instruction
    }

    init(dict: [String: String]) {
        self.name = dict["name"] ?? ""
        self.summary = dict["summary"] ?? ""
        self.instruction = dict["instruction"] ?? ""
    }
}

final class SkillStore {
    static let shared = SkillStore()
    private init() {}

    private var enabledKey = "trollmcp2.skills_enabled"

    private var kbURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase")
            .appendingPathComponent("skills.json")
    }

    /// 全部技能（含未启用的）
    var all: [SkillItem] {
        guard let data = try? Data(contentsOf: kbURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return json.map { SkillItem(dict: $0) }
    }

    /// 首次启动：无 skills.json 时写入内置示例技能，开箱即用
    func seedIfEmpty() {
        guard !FileManager.default.fileExists(atPath: kbURL.path) else { return }
        let builtins: [[String: String]] = [
            [
                "name": "翻译润色",
                "summary": "中英等多语言互译与文字润色，去掉生硬翻译腔，贴合目标语言习惯",
                "instruction": "当用户要求翻译或润色文字时执行本技能：\n1. 先确认源语言与目标语言；\n2. 翻译时以自然、地道为目标，避免逐字直译和机翻腔；\n3. 涉及专业术语时保留原文并附注；\n4. 润色时保持原意，调整句式与用词，使其更通顺、更符合目标读者习惯。",
            ],
            [
                "name": "代码审查",
                "summary": "审查代码的安全、性能、可读性与逻辑正确性，输出问题清单",
                "instruction": "当用户提供代码片段或要求审查时执行本技能：\n1. 先识别语言与用途；\n2. 按 安全漏洞(注入/XSS/越权)、性能、可读性、边界情况 四类检查；\n3. 每个问题给出 位置、风险等级、修复建议；\n4. 最后给出总体结论与优先级排序。",
            ],
            [
                "name": "Tweak 开发助手",
                "summary": "Theos Tweak 开发全流程指导：工程结构、Makefile、打包、GitHub Actions 线上编译",
                "instruction": "当用户涉及 Tweak 开发时执行本技能：\n1. 工程需包含 Makefile / Tweak.x / .plist；\n2. 提示 Theos 需 submodules: recursive 克隆，GitHub Actions 用 macos-14 runner + brew install ldid；\n3. 打包用 make clean package FINALPACKAGE=1；\n4. 产物为 .deb/.dylib，可用 TrollFools 注入测试。",
            ],
            [
                "name": "客服回复",
                "summary": "电商/独立站客户消息的礼貌得体回复，处理售前、物流、退换货、差评",
                "instruction": "当用户要求撰写客户回复时执行本技能：\n1. 先判断场景（售前咨询/催发货/物流/退换货/差评）；\n2. 语气礼貌、专业、简洁，先共情再解决问题；\n3. 涉及退款/补偿给出清晰选项；\n4. 英文客服回复需自然口语化，避免生硬模板腔。",
            ],
        ]
        save(builtins.map { SkillItem(dict: $0) })
    }

    /// 写入全部技能（覆盖式）
    func save(_ items: [SkillItem]) {
        try? FileManager.default.createDirectory(
            at: kbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = items.map { $0.dict }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: kbURL)
        }
        AuditLog.shared.log("skills", detail: "已保存 \(items.count) 个技能")
    }

    func upsert(_ item: SkillItem) {
        var list = all
        if let idx = list.firstIndex(where: { $0.name == item.name }) {
            list[idx] = item
        } else {
            list.append(item)
        }
        save(list)
    }

    func delete(named name: String) {
        save(all.filter { $0.name != name })
    }

    func item(named name: String) -> SkillItem? {
        all.first { $0.name == name }
    }

    /// 技能是否启用（默认启用；仅显式禁用才关）
    func isEnabled(_ name: String) -> Bool {
        let dict = UserDefaults.standard.object(forKey: enabledKey) as? [String: Bool] ?? [:]
        if let v = dict[name] { return v }
        return true
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        var dict = UserDefaults.standard.object(forKey: enabledKey) as? [String: Bool] ?? [:]
        if enabled {
            dict.removeValue(forKey: name)
        } else {
            dict[name] = false
        }
        UserDefaults.standard.set(dict, forKey: enabledKey)
        AuditLog.shared.log("skills", detail: "\(name) \(enabled ? "启用" : "停用")")
    }
}

// MARK: - AI 技能工具（模型可发现/读取/启用）

/// skills.list：列出已启用技能（名称+摘要），供模型判断何时使用
final class SkillsListTool: MCPTool {
    let definition = ToolDefinition(
        name: "skills.list",
        summary: "列出当前可用的技能（名称+用途摘要）。技能是预置的工作流指令，需要执行某项技能时先 list 再 read。",
        parameters: [:])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let items = SkillStore.shared.all.filter { SkillStore.shared.isEnabled($0.name) }
        return [
            "total": items.count,
            "skills": items.map { ["name": $0.name, "summary": $0.summary] },
            "hint": "需要执行某个技能时，用 skills.read 读取其完整指令。"
        ]
    }
}

/// skills.read：读取某技能的完整指令
final class SkillsReadTool: MCPTool {
    let definition = ToolDefinition(
        name: "skills.read",
        summary: "读取指定技能的完整指令，按指令执行该技能。",
        parameters: ["name": "技能名称"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        guard let item = SkillStore.shared.item(named: name) else {
            throw MCPError.invalidParams("技能不存在: \(name)")
        }
        return ["name": item.name, "summary": item.summary, "instruction": item.instruction]
    }
}
