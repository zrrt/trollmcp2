import SwiftUI

// MARK: - v2.9.90 图标主题切换（借鉴 Fuck 巨魔工具箱 4 套图标设计）
// blueIcon（巨魔蓝默认）/ originalIcon（蓝紫）/ whiteIcon（浅白）/ outsetIcon（深青）

struct IconThemeView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let themes: [(id: String, name: String, file: String)] = [
        ("blueIcon", "巨魔蓝", "blueIcon-1024x1024"),
        ("originalIcon", "蓝紫", "originalIcon-1024x1024"),
        ("whiteIcon", "浅白", "whiteIcon-1024x1024"),
        ("outsetIcon", "深青", "outsetIcon-1024x1024"),
    ]

    @State private var current: String = {
        // 读取当前生效的图标名（nil = 主图标）
        if #available(iOS 14.0, *) {
            return UIApplication.shared.alternateIconName ?? "blueIcon"
        }
        return "blueIcon"
    }()
    @State private var switching = false
    @State private var appliedName = ""
    @State private var applyError = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: colorScheme == .dark
                           ? [Color(red: 0.09, green: 0.11, blue: 0.16), Color(red: 0.12, green: 0.14, blue: 0.20)]
                           : [Color(red: 0.90, green: 0.94, blue: 1.0), .white],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("选择图标主题，立即生效（无需重新安装）")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)

                    ForEach(themes, id: \.id) { theme in
                        Button {
                            apply(theme.id)
                        } label: {
                            HStack(spacing: 16) {
                                Image(uiImage: UIImage(named: theme.file) ?? UIImage())
                                    .resizable()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(current == theme.id ? Color.blue : Color.clear, lineWidth: 3)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(theme.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(current == theme.id ? "当前使用中" : "点击切换")
                                        .font(.caption)
                                        .foregroundColor(current == theme.id ? Color.blue : .secondary)
                                }
                                Spacer()
                                if current == theme.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                        .font(.title3)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.9))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(colorScheme == .dark ? 0.25 : 0.12), lineWidth: 1))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if switching {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("切换中…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    if !appliedName.isEmpty {
                        Text("✅ 已切换到「\(appliedName)」，主屏幕图标稍后更新")
                            .font(.subheadline)
                            .foregroundColor(.green)
                            .padding(.vertical, 4)
                    }
                    if !applyError.isEmpty {
                        Text("⚠️ \(applyError)")
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .padding(.vertical, 4)
                    }

                    Text("说明：TrollStore 安装的 App 同样支持动态图标切换（CFBundleAlternateIcons）。若切换后桌面图标未变，请重启一次桌面（锁屏重开）。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("图标主题")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func apply(_ id: String) {
        guard !switching else { return }
        switching = true
        appliedName = ""
        applyError = ""
        UIApplication.shared.setAlternateIconName(id == "blueIcon" ? nil : id) { error in
            DispatchQueue.main.async {
                switching = false
                if let error = error {
                    applyError = "切换失败：\(error.localizedDescription)"
                } else {
                    current = id
                    appliedName = themes.first(where: { $0.id == id })?.name ?? id
                }
            }
        }
    }
}
