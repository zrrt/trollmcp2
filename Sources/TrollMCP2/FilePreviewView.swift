import SwiftUI
import UIKit
import QuickLook

/// v3.1.6: 聊天文件预览 —— QLPreviewController 的 SwiftUI 包装
/// 用户在聊天里点文件卡片 → 直接打开系统 QuickLook 预览（图片/ipa/tipa/文本/plist 等）
struct FilePreviewView: UIViewControllerRepresentable {
    let urls: [URL]
    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let parent: FilePreviewView
        init(_ parent: FilePreviewView) { self.parent = parent }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            parent.urls.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            let valid = parent.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            return valid[index] as NSURL
        }
    }
}

/// v3.1.6: 从工具结果文本中提取文件路径
/// 匹配常见路径格式：/var/mobile/... 或 ~/... 或 Workspace 下的相对路径
enum FilePathExtractor {
    /// 支持的文件扩展名（才显示文件卡片）
    static let previewableExts: Set<String> = [
        "png","jpg","jpeg","gif","webp","heic","heif",
        "plist","json","txt","log","md","swift","h","m","mm","c","cpp",
        "ipa","tipa","deb","zip","tar","gz",
        "dylib","framework","app",
        "pdf","html","css","js",
        "macho","bin","nib","xcassets"
    ]

    /// 从文本中提取所有存在于磁盘上的文件路径
    static func extractFiles(from text: String) -> [URL] {
        var results: [URL] = []
        var seen = Set<String>()

        // 正则匹配常见路径
        let patterns = [
            #"/var/mobile/[^\s"'\)\]},，。；：]+"#,
            #"/var/containers/[^\s"'\)\]},，。；：]+"#,
            #"/private/var/[^\s"'\)\]},，。；：]+"#,
            #"~/Documents/[^\s"'\)\]},，。；：]+"#,
            #"Workspace/[^\s"'\)\]},，。；：]+"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let r = Range(match.range, in: text) else { return }
                var path = String(text[r])
                // 去掉尾部标点
                while let last = path.last, "。，；：,.;:)）]】".contains(last) {
                    path.removeLast()
                }
                // 展开 ~
                if path.hasPrefix("~") {
                    path = NSHomeDirectory() + path.dropFirst()
                }
                // Workspace/xxx → 绝对路径
                if path.hasPrefix("Workspace/") {
                    path = Workspace.root.path + "/" + path.dropFirst("Workspace/".count)
                }
                // 检查文件是否存在 + 扩展名在白名单
                guard FileManager.default.fileExists(atPath: path) else { return }
                let ext = (path as NSString).pathExtension.lowercased()
                guard previewableExts.contains(ext) else { return }
                guard !seen.contains(path) else { return }
                seen.insert(path)
                results.append(URL(fileURLWithPath: path))
            }
        }

        return results
    }
}
