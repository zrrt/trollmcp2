import SwiftUI
import UIKit

/// v3.1.6: 聊天文件预览 —— 自建预览（v4.3.48 重构）
///
/// ⚠️ v4.3.48 重大变更：**不再使用 QLPreviewController**。
/// QLPreviewController 导航栏自带**系统分享按钮**，用户点它会弹系统分享面板
/// （ShareSheet）→ 在本设备侧载环境触发 MobileIcons/CoreImage SIGSEGV
/// （崩溃栈实证：ShareSheet → SharingUI → MobileIcons LICreateIconForImages → CoreImage）。
/// 改为自建预览：图片/文本直接渲染，其他类型显示图标+信息，
/// 分享操作只用自建按钮（存储到文件 / 用其他 App 打开），彻底绕开 ShareSheet。
struct QLFilePreview: View {
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss

    private var url: URL? {
        urls.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var fileName: String { url?.lastPathComponent ?? "未知文件" }
    private var ext: String { (fileName as NSString).pathExtension.lowercased() }

    private var sizeText: String {
        guard let url = url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        if size > 1024 * 1024 { return String(format: "%.1f MB", Double(size) / 1024 / 1024) }
        if size > 1024 { return String(format: "%.0f KB", Double(size) / 1024) }
        return "\(size) B"
    }

    private var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"].contains(ext) }
    private var isText: Bool { ["txt", "log", "md", "json", "plist", "swift", "h", "m", "mm", "c", "cpp", "html", "css", "js", "xml", "yml", "yaml", "ini", "conf", "sh"].contains(ext) }

    var body: some View {
        NavigationView {
            content
                .navigationTitle(fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("完成") { dismiss() }
                    }
                    // 注意：toolbar 内不可用 if 分支（buildIf 需 iOS 16+，项目最低 iOS 14），
                    // 改为始终显示、无文件时禁用
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 16) {
                            Button {
                                if let url = url { ShareCenter.shared.saveToFiles(url) }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .disabled(url == nil)
                            Button {
                                if let url = url { ShareCenter.shared.openIn(url) }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .disabled(url == nil)
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var content: some View {
        if let url = url {
            if isImage {
                imageView(url)
            } else if isText {
                textView(url)
            } else {
                genericView(url)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("文件不存在")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func imageView(_ url: URL) -> some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                if let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Text("无法渲染图片")
                        .foregroundColor(.secondary)
                }
            }
            .background(Color.black)
        }
    }

    private func textView(_ url: URL) -> some View {
        ScrollView {
            Text(readText(url) ?? "无法读取")
                .font(.system(.footnote, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func genericView(_ url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 56))
                .foregroundColor(.tmCyan)
            Text(fileName)
                .font(.subheadline)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
            Text(sizeText)
                .font(.caption)
                .foregroundColor(.secondary)
            Text("此类型无法直接预览，可用上方按钮存储到文件或用其他 App 打开")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var iconName: String {
        switch ext {
        case "ipa", "tipa": return "shippingbox"
        case "deb", "zip", "tar", "gz": return "archivebox"
        case "dylib", "framework": return "hammer"
        case "plist", "json": return "doc.text"
        case "pdf": return "doc.richtext"
        case "app": return "app.badge"
        default: return "doc"
        }
    }

    private func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 先试 UTF-8，失败退 ASCII/GBK
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .ascii) { return s }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gbk) { return s }
        return nil
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
            #"/var/mobile/[^\s"'\)\]},。，；：]+"#,
            #"/var/containers/[^\s"'\)\]},。，；：]+"#,
            #"/private/var/[^\s"'\)\]},。，；：]+"#,
            #"~/Documents/[^\s"'\)\]},。，；：]+"#,
            #"Workspace/[^\s"'\)\]},。，；：]+"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match = match, let r = Range(match.range, in: text) else { return }
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
