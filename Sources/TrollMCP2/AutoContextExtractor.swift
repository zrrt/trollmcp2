import Foundation
import SwiftUI
import Combine

// MARK: - 自动上下文提取器
// 自动从用户消息中提取关键信息（App 名、bundle id、文件路径等）
// 存到上下文里，下次用户问的时候自动加进去

final class AutoContextExtractor: ObservableObject {
    static let shared = AutoContextExtractor()

    // 提取到的关键信息
    @Published var lastBundleID: String?
    @Published var lastAppName: String?
    @Published var lastFilePath: String?
    @Published var lastProject: String?
    @Published var lastAction: String?

    private init() {}

    /// 从用户消息中提取关键信息
    func extract(from message: String) {
        // 1. 提取 bundle id（com.xxx.xxx 格式）
        if let bundleID = extractBundleID(from: message) {
            lastBundleID = bundleID
            print("📝 AutoContext: extracted bundle_id = \(bundleID)")
        }

        // 2. 提取文件路径（/var/mobile/... 或 ~/... 格式）
        if let filePath = extractFilePath(from: message) {
            lastFilePath = filePath
            print("📝 AutoContext: extracted file_path = \(filePath)")
        }

        // 3. 提取 App 名（简单版：常见 App 名匹配）
        if let appName = extractAppName(from: message) {
            lastAppName = appName
            print("📝 AutoContext: extracted app_name = \(appName)")
        }

        // 4. 提取操作类型（用户想做什么）
        if let action = extractAction(from: message) {
            lastAction = action
            print("📝 AutoContext: extracted action = \(action)")
        }
    }

    /// 生成上下文提示，加到系统提示词里
    func contextHint() -> String? {
        var hints: [String] = []

        if let bundleID = lastBundleID {
            hints.append("Last mentioned app bundle_id: \(bundleID)")
        }
        if let appName = lastAppName {
            hints.append("Last mentioned app: \(appName)")
        }
        if let filePath = lastFilePath {
            hints.append("Last mentioned file: \(filePath)")
        }
        if let action = lastAction {
            hints.append("Last action: \(action)")
        }

        guard !hints.isEmpty else { return nil }

        return """
        
        === AUTO CONTEXT (extracted from recent conversation) ===
        \(hints.joined(separator: "\n"))
        If user says "it" / "this app" / "it's file" / "do it", use the above context.
        """
    }

    // MARK: - 提取器

    /// 提取 bundle id
    private func extractBundleID(from text: String) -> String? {
        // 匹配 com.xxx.xxx 格式
        let pattern = #"com\.[a-zA-Z0-9]+\.[a-zA-Z0-9.]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    /// 提取文件路径
    private func extractFilePath(from text: String) -> String? {
        // 匹配 /var/mobile/... 或 ~/Documents/... 格式
        let pattern = #"(/var/mobile/[^\s]+|~/[^\s]+|/private/var/[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    /// 提取常见 App 名（简单版）
    private func extractAppName(from text: String) -> String? {
        let knownApps = [
            "微信": "com.tencent.xin",
            "小红书": "com.xingin.xhs",
            "抖音": "com.ss.iphone.ugc.Aweme",
            "淘宝": "com.taobao.taobao",
            "支付宝": "com.alipay.iphoneclient",
            "QQ": "com.tencent.mqq",
            "百度": "com.baidu.searchbox",
            "B站": "tv.danmaku.bili",
            "哔哩哔哩": "tv.danmaku.bili",
            "微博": "com.sina.weibo",
            "网易云音乐": "com.netease.163music",
            "QQ音乐": "com.tencent.QQMusic",
            "快手": "com.smile.gifmaker",
            "美团": "com.sankuai.meituan",
            "饿了么": "me.ele.iphone",
            "携程": "ctrip.iphone",
            "京东": "com.jd.iphone",
            "拼多多": "com.xunmeng.pinduoduo",
            "闲鱼": "com.taobao.fleamarket",
            "钉钉": "com.laiwang.DingTalk",
            "飞书": "com.larksuite.lark",
        ]

        for (name, _) in knownApps {
            if text.contains(name) {
                return name
            }
        }

        return nil
    }

    /// 提取操作类型（用户想做什么）
    func extractAction(from text: String) -> String? {
        let actions = [
            "分析": "分析 App 结构",
            "抓包": "网络抓包分析",
            "注入": "注入 dylib",
            "截图": "截图",
            "录屏": "录屏",
            "清理": "清理缓存",
            "备份": "备份",
            "恢复": "恢复",
            "安装": "安装 App",
            "卸载": "卸载 App",
            "启动": "启动 App",
            "重启": "重启 App",
            "停止": "停止 App",
            "修改": "修改内容",
            "读取": "读取内容",
            "写入": "写入内容",
            "删除": "删除内容",
        ]

        for (action, _) in actions {
            if text.contains(action) {
                return action
            }
        }

        return nil
    }
}
