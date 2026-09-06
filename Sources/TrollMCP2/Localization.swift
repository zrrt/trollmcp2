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
            // v2.9.79：聊天框模型条
            "current_model": ["zh": "当前模型", "en": "Model"],
            "not_configured": ["zh": "未配置", "en": "Not set"],
            // v2.9.82：任务完成通知
            "task_notify": ["zh": "任务完成通知", "en": "Task Notification"],
            "task_notify_sub": ["zh": "AI 执行完成/失败时，后台发本地通知", "en": "Notify when AI finishes or fails in background"],

            // ===== 首页 =====
            "home_greeting": ["zh": "你好，我是 TrollAgent", "en": "Hi, I'm TrollAgent"],
            "home_subtitle": ["zh": "TrollStore 上的 AI 实验与 QA 工作台\n分析 · 注入 · 编译 · 控制", "en": "AI lab & QA workbench for TrollStore\nAnalyze · Inject · Build · Control"],
            "home_analyze_apps": ["zh": "分析我的应用", "en": "Analyze My Apps"],
            "home_analyze_apps_sub": ["zh": "扫描缓存、注入状态与已安装应用", "en": "Scan caches, injection state & installed apps"],
            "home_check_device": ["zh": "检查设备与内存", "en": "Check Device & Memory"],
            "home_check_device_sub": ["zh": "设备信息、可用容量与环境检测", "en": "Device info, storage & environment probe"],
            "home_empty_title": ["zh": "尚未配置模型", "en": "No model configured"],
            "home_empty_sub": ["zh": "请先在设置中添加 API 配置", "en": "Add an API config in Settings first"],
            "home_thinking": ["zh": "正在思考", "en": "Thinking"],
            "home_running_tool": ["zh": "正在执行工具", "en": "Running tool"],
            "home_round": ["zh": "第 {n}/{total} 轮", "en": "Round {n}/{total}"],
            // v2.9.78：首页快速引导区
            "home_quick_title": ["zh": "快速开始", "en": "Quick Start"],
            "home_quick_sub": ["zh": "点击卡片直接体验 · 也可输入自己的指令", "en": "Tap a card to try, or type your own"],
            "home_quick_compile": ["zh": "线上编译", "en": "Cloud Build"],
            "home_quick_compile_sub": ["zh": "GitHub 编译 tweak / IPA", "en": "Build tweak / IPA on GitHub"],
            "home_quick_inject": ["zh": "注入测试", "en": "Injection Test"],
            "home_quick_inject_sub": ["zh": "给 App 注入 dylib 并验证", "en": "Inject & verify a dylib"],
            "home_quick_memory": ["zh": "内存修改", "en": "Memory Tweak"],
            "home_quick_memory_sub": ["zh": "H5gg 式搜索与修改", "en": "H5gg-style search & patch"],
            "home_quick_ui": ["zh": "UI 控制", "en": "UI Control"],
            "home_quick_ui_sub": ["zh": "控制任意 App 界面", "en": "Drive any app's UI"],
            "home_quick_browser": ["zh": "内置浏览器", "en": "Built-in Browser"],
            "home_quick_browser_sub": ["zh": "网页操作与抓取", "en": "Browse & scrape pages"],
            "home_quick_automation": ["zh": "自动化", "en": "Automation"],
            "home_quick_automation_sub": ["zh": "定时任务与重试", "en": "Scheduled tasks & retries"],

            // ===== 新手引导（v2.9.78）=====
            "ob_skip": ["zh": "跳过", "en": "Skip"],
            "ob_next": ["zh": "下一步", "en": "Next"],
            "ob_done": ["zh": "开始使用", "en": "Get Started"],
            "ob_welcome_title": ["zh": "欢迎使用 TrollAgent", "en": "Welcome to TrollAgent"],
            "ob_welcome_sub": ["zh": "TrollStore 上的 AI 实验与 QA 工作台：一句话描述目标，AI 自动完成诊断、操作、验证与报告。", "en": "An AI lab for TrollStore: describe a goal, and AI handles diagnosis, actions, verification and reporting."],
            "ob_cap_title": ["zh": "它能做什么", "en": "What it can do"],
            "ob_cap1": ["zh": "线上编译 tweak / IPA 并下载注入", "en": "Cloud-build tweaks / IPAs, download & inject"],
            "ob_cap2": ["zh": "H5gg 式内存搜索与修改", "en": "H5gg-style memory search & patch"],
            "ob_cap3": ["zh": "读取界面树、点击输入，控制任意 App", "en": "Read UI tree, tap & type to drive any app"],
            "ob_cap4": ["zh": "内置浏览器、审计、自动化与知识库", "en": "Built-in browser, audit, automation & KB"],
            "ob_start_title": ["zh": "开始使用", "en": "Get Started"],
            "ob_start_sub": ["zh": "先到「设置 → 模型 API」添加你的中转站配置，然后回来试试下方的快捷卡片。", "en": "Add your relay API config under Settings → Model API, then try the quick cards below."],

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

            // ===== 子页面标题 =====
            "page_remote": ["zh": "远程控制", "en": "Remote Control"],
            "page_remote_sub": ["zh": "AI 控制任意 App 的 UI：读取界面、点击、输入、滑动", "en": "AI controls any app UI: read, tap, type, swipe"],
            "page_inject": ["zh": "注入与自动化", "en": "Injection & Automation"],
            "page_inject_sub": ["zh": "dylib 注入 · 应用列表 · 自动化策略", "en": "dylib injection · apps · automation"],
            "page_downloads": ["zh": "下载管理", "en": "Downloads"],
            "page_downloads_sub": ["zh": "线上编译产物 · 勾选删除 · 安装", "en": "Build artifacts · select & delete · install"],
            "page_audit": ["zh": "本机工具审计", "en": "Tool Audit"],
            "page_audit_sub": ["zh": "工具调用记录 · 成功/失败 · 导出给 AI", "en": "Tool calls · success/fail · export to AI"],
            "page_netlog": ["zh": "网络兼容日志", "en": "Network Log"],
            "page_netlog_sub": ["zh": "中转站兼容性 · 降级记录", "en": "Relay compatibility & fallback log"],
            "page_dev_instr": ["zh": "开发者指令", "en": "Developer Instructions"],
            "page_dev_instr_sub": ["zh": "编辑 · 复制 · 设置默认 · 注入 AI 行为", "en": "Edit · copy · set default · shape AI behavior"],
            "page_automation": ["zh": "自动化中心", "en": "Automation Center"],
            "page_automation_sub": ["zh": "定时任务 · 历史 · 重试", "en": "Scheduled tasks · history · retry"],
            "page_tool_policy": ["zh": "工具权限策略", "en": "Tool Permissions"],
            "page_tool_policy_sub": ["zh": "按工具控制 · 真实/占位 · 搜索即授权", "en": "Per-tool control · real/stub · search-to-authorize"],
            "page_transcripts": ["zh": "会话记录", "en": "Transcripts"],
            "page_transcripts_sub": ["zh": "完整对话存档 · 导出", "en": "Full chat archive · export"],
            "page_search": ["zh": "内置智能搜索", "en": "Smart Search"],
            "page_search_sub": ["zh": "Bing Web 搜索 · 用法说明", "en": "Bing web search · usage"],
            "page_gateway": ["zh": "Gateway 设置", "en": "Gateway Settings"],
            "page_gateway_sub": ["zh": "服务端管理 · 远程接入", "en": "Server management · remote access"],
            "page_agents": ["zh": "Agents 与 Skills", "en": "Agents & Skills"],
            "page_agents_sub": ["zh": "隔离指令 · 技能 · 工作流", "en": "Isolated prompts · skills · workflows"],
            "page_kb": ["zh": "本机知识库", "en": "Knowledge Base"],
            "page_kb_sub": ["zh": "文件导入 · 来源检索 · 问答增强", "en": "Import files · source search · RAG"],
            "page_webhooks": ["zh": "Webhooks", "en": "Webhooks"],
            "page_webhooks_sub": ["zh": "HTTPS 事件出口 · 订阅管理", "en": "HTTPS event output · subscriptions"],
            "page_data": ["zh": "数据管理", "en": "Data Management"],
            "page_data_sub": ["zh": "App 文稿目录 · 备份与清理", "en": "App Documents · backup & clean"],
            "page_capabilities": ["zh": "权限与自动化", "en": "Permissions & Automation"],
            "page_capabilities_sub": ["zh": "系统能力检测 · 权限开关", "en": "System capabilities · permission toggles"],
            "page_apikeys": ["zh": "API Key 管理", "en": "API Keys"],
            "page_apikeys_sub": ["zh": "查看 · 显隐 · 恢复", "en": "View · show/hide · recover"],
            "page_ssh": ["zh": "SSH 远程连接", "en": "SSH Remote"],
            "page_ssh_sub": ["zh": "Linux 远程命令 · 文件传输", "en": "Remote Linux commands · file transfer"],
            "page_env": ["zh": "本机环境检测", "en": "Environment Check"],
            "page_env_sub": ["zh": "TrollStore · 权限 · 注入链路", "en": "TrollStore · permissions · injection chain"],

            // ===== 常用按钮 =====
            "btn_install": ["zh": "安装", "en": "Install"],
            "btn_export": ["zh": "导出", "en": "Export"],
            "btn_import": ["zh": "导入", "en": "Import"],
            "btn_new": ["zh": "新建", "en": "New"],
            "btn_edit": ["zh": "编辑", "en": "Edit"],
            "btn_retry": ["zh": "重试", "en": "Retry"],
            "btn_stop": ["zh": "停止", "en": "Stop"],
            "btn_test": ["zh": "测试", "en": "Test"],
            "btn_clear": ["zh": "清空", "en": "Clear"],
            "btn_save_config": ["zh": "保存配置", "en": "Save Config"],
            "btn_check_connection": ["zh": "检查连接", "en": "Check Connection"],
            "status_connected": ["zh": "已连接", "en": "Connected"],
            "status_disconnected": ["zh": "未连接", "en": "Disconnected"],
            "status_checking": ["zh": "检查中...", "en": "Checking..."],
        ]
        return table[key]?[lang] ?? key
    }
}