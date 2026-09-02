import SwiftUI
import UIKit

// MARK: - 下载管理（v2.9.10）
// 管理 GitHub 线上编译产物下载目录（Workspace/downloads）。
// 支持浏览子目录、勾选删除、查看文件大小与类型。

struct DownloadsView: View {
    @State private var items: [DownloadItem] = []
    @State private var selected = Set<UUID>()
    @State private var editMode = false
    @State private var showConfirm = false
    @State private var confirmMessage = ""
    @State private var refreshTick = false

    struct DownloadItem: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let isDir: Bool
        let sizeText: String
        let dateText: String
    }

    private var downloadsDir: URL {
        Workspace.root.appendingPathComponent("downloads", isDirectory: true)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        Section(header: SettingSectionHeader(title: "下载产物")) {
                            ForEach(items) { item in
                                row(item)
                            }
                            .onDelete { indexSet in
                                let targets = indexSet.map { items[$0] }
                                for t in targets { try? FileManager.default.removeItem(atPath: t.path) }
                                refresh()
                            }
                        }
                    }
                    .listStyle(.plain)
                }
                toolbar
            }
            .navigationTitle("下载管理")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button(editMode ? "完成" : "选择") {
                    withAnimation { editMode.toggle() }
                    if !editMode { selected.removeAll() }
                },
                trailing: Button(action: refresh) { Image(systemName: "arrow.clockwise") }
            )
            .alert(isPresented: $showConfirm) {
                Alert(
                    title: Text("删除所选"),
                    message: Text(confirmMessage),
                    primaryButton: .destructive(Text("删除")) {
                        deleteSelected()
                    },
                    secondaryButton: .cancel()
                )
            }
            .onAppear { refresh() }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("暂无下载")
                .font(.headline)
            Text("线上编译产物会保存在\nDocuments/Workspace/downloads/")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            if editMode {
                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(selected.contains(item.id) ? .blue : .secondary)
            }
            Image(systemName: item.isDir ? "folder.fill" : iconFor(item.name))
                .font(.system(size: 22))
                .foregroundColor(item.isDir ? .blue : .gray)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.sizeText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(item.dateText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if editMode {
                if selected.contains(item.id) {
                    selected.remove(item.id)
                } else {
                    selected.insert(item.id)
                }
            }
        }
        .contextMenu {
            Button(action: { try? FileManager.default.removeItem(atPath: item.path); refresh() }) {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(editMode ? "已选 \(selected.count) 项" : "\(items.count) 个文件/文件夹")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                if editMode {
                    Button(action: {
                        let cnt = selected.count
                        guard cnt > 0 else { return }
                        confirmMessage = "将删除 \(cnt) 项，不可恢复"
                        showConfirm = true
                    }) {
                        Text("删除所选")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(selected.isEmpty ? .gray : .red)
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    private func iconFor(_ name: String) -> String {
        if name.hasSuffix(".zip") { return "doc.zipper" }
        if name.hasSuffix(".dylib") { return "cube.fill" }
        if name.hasSuffix(".deb") { return "shippingbox.fill" }
        if name.hasSuffix(".png") || name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") { return "photo.fill" }
        return "doc.fill"
    }

    private func refresh() {
        let fm = FileManager.default
        try? fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            items = []
            return
        }
        items = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url -> DownloadItem in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d HH:mm"
            return DownloadItem(
                name: url.lastPathComponent,
                path: url.path,
                isDir: isDir,
                sizeText: humanSize(size, isDir: isDir),
                dateText: formatter.string(from: date)
            )
        }
    }

    private func humanSize(_ bytes: Int, isDir: Bool) -> String {
        if isDir { return "文件夹" }
        let kb = Double(bytes) / 1024.0
        if kb < 1 { return "\(bytes) B" }
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", kb / 1024.0)
    }

    private func deleteSelected() {
        for item in items where selected.contains(item.id) {
            try? FileManager.default.removeItem(atPath: item.path)
        }
        selected.removeAll()
        withAnimation { editMode = false }
        refresh()
    }
}
