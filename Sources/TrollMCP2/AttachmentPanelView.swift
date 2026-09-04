import SwiftUI
import UIKit
import PhotosUI

enum AttachmentSheet: Identifiable {
    case panel
    case appPicker
    case photoPicker
    case documentPicker

    var id: Int {
        switch self {
        case .panel: return 0
        case .appPicker: return 1
        case .photoPicker: return 2
        case .documentPicker: return 3
        }
    }
}

struct AttachmentPanelView: View {
    var onPick: (AttachmentSheet) -> Void
    /// v2.9.35：已选附件数量（对齐老 MCP 右上角"已选 N"徽标）
    var selectedCount: Int = 0
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加内容")
                        .font(.headline)
                    Text("仅用于本轮请求，本机准备")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                // v2.9.35：已选数量徽标
                if selectedCount > 0 {
                    Text("已选 \(selectedCount)")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(10)
                        .padding(.trailing, 6)
                }
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.blue)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            HStack(spacing: 24) {
                AttachmentOption(
                    icon: "square.grid.2x2",
                    title: "应用",
                    subtitle: "选择分析"
                ) {
                    presentationMode.wrappedValue.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onPick(.appPicker)
                    }
                }
                AttachmentOption(
                    icon: "photo.on.rectangle",
                    title: "相册",
                    subtitle: "最多 8 张"
                ) {
                    presentationMode.wrappedValue.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onPick(.photoPicker)
                    }
                }
                AttachmentOption(
                    icon: "paperclip",
                    title: "文件",
                    subtitle: "最多 8 个"
                ) {
                    presentationMode.wrappedValue.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onPick(.documentPicker)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 30)
        }
    }
}

struct AttachmentOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(.blue)
                    .frame(width: 60, height: 60)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(16)
                VStack(spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 相册选择器（iOS 14+ PHPicker）

struct PhotoPickerView: UIViewControllerRepresentable {
    var onSelect: ([URL]) -> Void
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 8
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerView
        init(_ parent: PhotoPickerView) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentationMode.wrappedValue.dismiss()
            var urls: [URL] = []
            let group = DispatchGroup()
            for result in results {
                group.enter()
                // v2.9.9：优先复制到沙盒临时目录，保证 onSelect 后 URL 仍可读（原 itemProvider 临时文件可能立即失效）
                result.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.image") { url, error in
                    if let url = url {
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent("trollmcp_img_\(UUID().uuidString).jpg")
                        try? FileManager.default.copyItem(at: url, to: dest)
                        urls.append(dest)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.parent.onSelect(urls)
            }
        }
    }
}

// MARK: - 文件选择器

struct DocumentPickerView: UIViewControllerRepresentable {
    var onSelect: ([URL]) -> Void
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .open)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView
        init(_ parent: DocumentPickerView) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.presentationMode.wrappedValue.dismiss()
            parent.onSelect(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
