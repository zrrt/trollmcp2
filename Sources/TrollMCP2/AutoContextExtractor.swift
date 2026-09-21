import Foundation
import SwiftUI

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

        guard !hints.isEmpty else { return nil }

        return """
        
        === AUTO CONTEXT (extracted from recent conversation) ===
        \(hints.joined(separator: "\n"))
        If user says "it" / "this app" / "it's file", use the above context.
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
        ]

        for (name, _) in knownApps {
            if text.contains(name) {
                return name
            }
        }

        return nil
    }
}
