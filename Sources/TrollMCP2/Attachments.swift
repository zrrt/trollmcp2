import SwiftUI
import UIKit

// MARK: - 待发送附件（v2.9.10）
// 统一图片 / 应用 / 文件三种选择结果，输入栏上方显示预览缩略图，可删除。

struct PendingAttachment: Identifiable {
    enum Kind {
        case image    // 相册图片（dataURL + 缩略图）
        case app      // 应用（图标 + 名称 + bundleId）
        case file     // 文件（类型图标 + 文件名）
    }
    let id = UUID()
    let kind: Kind
    let displayName: String
    let dataURL: String?      // 图片用：data:image/jpeg;base64,...
    let thumbnail: UIImage?   // 图片缩略图 / 应用图标
    let bundleId: String?     // 应用用
    let fileURL: URL?         // 文件用
}

// MARK: - 输入栏附件预览行（横向滚动缩略图）
struct AttachmentPreviewStrip: View {
    let attachments: [PendingAttachment]
    let onRemove: (PendingAttachment) -> Void

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(attachments) { att in
                        ZStack(alignment: .topTrailing) {
                            preview(att)
                            Button(action: { onRemove(att) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.6)))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 72)
        }
    }

    @ViewBuilder
    private func preview(_ att: PendingAttachment) -> some View {
        switch att.kind {
        case .image:
            if let img = att.thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .cornerRadius(10)
                    .clipped()
            } else {
                placeholder(icon: "photo", label: att.displayName)
            }
        case .app:
            HStack(spacing: 8) {
                if let icon = att.thumbnail {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
                Text(att.displayName)
                    .font(.footnote)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        case .file:
            placeholder(icon: "doc.fill", label: att.displayName)
        }
    }

    private func placeholder(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.white)
            Text(label)
                .font(.caption2)
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(width: 60, height: 60)
        .background(Color.gray.opacity(0.6))
        .cornerRadius(10)
    }
}
