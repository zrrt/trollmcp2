import SwiftUI

// v2.9.76：全局语言切换（中/英）
// 整个 App 主要界面文本跟随切换，默认中文
// 实现：内置字典映射，不依赖 .strings 文件（CI swift build 不编译 strings）

enum AppLanguage: String, CaseIterable {
    case zh = "zh"
    case en = "en"

    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "app_language")
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "app_language") ?? "zh"
        language = AppLanguage(rawValue: raw) ?? .zh
    }

    var isZh: Bool { language == .zh }
}

enum L10n {
    static func t(_ key: String) -> String {
        let lang = LanguageManager.shared.language.rawValue
        let table: [String: [String: String]] = [
            // ===== 通用 =====
            "settings": ["zh": "设置", "en": "Settings"],
            "back": ["zh": "返回", "en": "Back"],
            "done": ["zh": "完成", "en": "Done"],
            "cancel": ["zh": "取消", "en": "Cancel"],
            "save": ["zh": "保存", "en": "Save"],
            "close": ["zh": "关闭", "en": "Close"],
            "delete": ["zh": "删除", "en": "Delete"],
            "copy": ["zh": "复制", "en": "Copy"],
            "share": ["zh": "分享", "en": "Share"],
            "version": ["zh": "版本", "en": "Version"],
            "language": ["zh": "语言", "en": "Language"],
            "search": ["zh": "搜索", "en": "Search"],
            "refresh": ["zh": "刷新", "en": "Refresh"],
            "confirm": ["zh": "确定", "en": "OK"],
            "warning": ["zh": "提示", "en": "Notice"],
            "enabled": ["zh": "已开启", "en": "On"],
            "disabled": ["zh": "已关闭", "en": "Off"],

            // ===== 首页 =====
            "home_greeting": ["zh": "你好，我是 TrollAgent", "en": "Hi, I'm TrollAgent"],
            "home_subtitle": ["zh": "设备端 AI 工作台：分析应用、内存、签名与 UI 自动化", "en": "On-device AI workbench: apps, memory, signing & UI automation"],
            "home_analyze_apps": ["zh": "分析我的应用", "en": "Analyze My Apps"],
            "home_analyze_apps_sub": ["zh": "扫描缓存、注入状态与已安装应用", "en": "Scan caches, injection state & installed apps"],
            "home_check_device": ["zh": "检查设备与内存", "en": "Check Device & Memory"],
            "home_check_device_sub": ["zh": "设备信息、可用容量与环境检测", "en": "Device info, storage & environment probe"],
            "home_empty_title": ["zh": "尚未配置模型", "en": "No model configured"],
            "home_empty_sub": ["zh": "请先在设置中添加 API 配置", "en": "Add an API config in Settings first"],
            "home_thinking": ["zh": "正在思考", "en": "Thinking"],
            "home_running_tool": ["zh": "正在执行工具", "en": "Running tool"],
            "home_round": ["zh": "第 {n}/{total} 轮", "en": "Round {n}/{total}"],

            // ===== 抽屉 =====
            "drawer_title": ["zh": "对话", "en": "Chats"],
            "drawer_search": ["zh": "搜索对话内容...", "en": "Search conversations..."],
            "drawer_count": ["zh": "{n} 个本机对话", "en": "{n} conversations"],
            "drawer_delete": ["zh": "删除对话", "en": "Delete Chat"],
            "drawer_ready": ["zh": "就绪 · 可注入", "en": "Ready · Injectable"],
            "drawer_env_limited": ["zh": "环境受限 · 点按查看", "en": "Limited · Tap to view"],
            "drawer_probe": ["zh": "点按检测本机", "en": "Tap to probe"],

            // ===== 设置分组 =====
            "sec_models": ["zh": "模型", "en": "Models"],
            "sec_core": ["zh": "核心功能", "en": "Core"],
            "sec_dev": ["zh": "开发者选项", "en": "Developer"],
            "sec_security": ["zh": "安全", "en": "Security"],
            "sec_about": ["zh": "关于", "en": "About"],

            // ===== 设置行 =====
            "row_model_api": ["zh": "模型 API", "en": "Model API"],
            "row_data": ["zh": "数据管理", "en": "Data Management"],
            "row_dev_instructions": ["zh": "开发者指令", "en": "Developer Instructions"],
            "row_sys_prompts": ["zh": "系统指令", "en": "System Prompts"],
            "row_inject": ["zh": "注入与自动化", "en": "Injection & Automation"],
            "row_inject_sub": ["zh": "全应用 · 策略 · 自动化", "en": "Apps · Policy · Automation"],
            "row_remote": ["zh": "远程控制", "en": "Remote Control"],
            "row_remote_sub": ["zh": "AI 控制任意 App UI", "en": "AI controls any app UI"],
            "row_github": ["zh": "GitHub 账号", "en": "GitHub Account"],
            "row_downloads": ["zh": "下载管理", "en": "Downloads"],
            "row_dev_mode": ["zh": "开发者模式", "en": "Developer Mode"],
            "row_permissions": ["zh": "权限与自动化", "en": "Permissions & Automation"],
            "row_automation": ["zh": "自动化中心", "en": "Automation Center"],
            "row_tool_policy": ["zh": "工具权限策略", "en": "Tool Permissions"],
            "row_transcripts": ["zh": "会话记录", "en": "Transcripts"],
            "row_ssh": ["zh": "SSH 远程连接", "en": "SSH Remote"],
            "row_search": ["zh": "内置智能搜索", "en": "Smart Search"],
            "row_browser": ["zh": "内置浏览器", "en": "Built-in Browser"],
            "row_gateway": ["zh": "Gateway 设置", "en": "Gateway Settings"],
            "row_agents": ["zh": "Agents 与 Skills", "en": "Agents & Skills"],
            "row_kb": ["zh": "本机知识库", "en": "Knowledge Base"],
            "row_webhooks": ["zh": "Webhooks", "en": "Webhooks"],
            "row_audit": ["zh": "本机工具审计", "en": "Tool Audit"],
            "row_apikeys": ["zh": "API Key 管理", "en": "API Keys"],
            "row_env": ["zh": "本机环境检测", "en": "Environment Check"],
            "row_netlog": ["zh": "网络兼容日志", "en": "Network Log"],
            "row_check_update": ["zh": "检查更新", "en": "Check Update"],
            "row_lang": ["zh": "语言 / Language", "en": "Language / 语言"],
        ]
        return table[key]?[lang] ?? key
    }
}