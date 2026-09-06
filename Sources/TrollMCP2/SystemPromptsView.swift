import SwiftUI

// v2.9.74：系统指令选择页面
// 系统指令是 App 内置的、不可编辑的行为规范
// 用户可在此切换哪套作为默认，优先级高于开发者指令
// v2.9.76：界面优化——卡片化、图标、选中态美化

struct SystemPromptsView: View {
    @State private var selectedId = SystemPrompts.shared.selectedId
    @State private var expandedId: String? = nil

    private let promptIcons: [String: String] = [
        "default": "sparkles",
        "developer": "hammer.fill",
        "concise": "bolt.fill",
        "reverse": "magnifyingglass.circle.fill",
        "qa": "checkmark.seal.fill",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard

                VStack(spacing: 12) {
                    ForEach(SystemPrompts.builtin) { prompt in
                        promptCard(prompt)
                    }
                }
                .padding(.horizontal, 16)

                explainCard
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("row_sys_prompts"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // 顶部说明卡
    private var headerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("row_sys_prompts"))
                    .font(.headline)
                Text("App 内置行为规范 · 不可编辑 · 切换立即生效")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 16)
    }

    // 单个指令卡片
    private func promptCard(_ prompt: SystemPrompt) -> some View {
        let isSelected = selectedId == prompt.id
        let isExpanded = expandedId == prompt.id

        return VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                selectedId = prompt.id
                SystemPrompts.shared.select(prompt.id)
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected
                                ? LinearGradient(colors: [.tmCyan.opacity(0.9), .blue.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 40)
                        Image(systemName: promptIcons[prompt.id] ?? "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(isSelected ? .white : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(prompt.name)
                            .font(.headline)
                            .foregroundColor(isSelected ? .tmCyan : .primary)
                        Text(prompt.desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.tmCyan)
                    } else {
                        Image(systemName: "circle")
                            .font(.system(size: 22))
                            .foregroundColor(Color(.systemGray4))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        Text(prompt.content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                }
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.tmCyan.opacity(0.2), lineWidth: 1)
                )
            }

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedId = isExpanded ? nil : prompt.id
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isExpanded ? "收起内容" : "查看内容")
                        .font(.caption)
                }
                .foregroundColor(.tmCyan)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: isSelected ? Color.tmCyan.opacity(0.12) : .black.opacity(0.04), radius: isSelected ? 8 : 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.tmCyan.opacity(0.45) : Color.clear, lineWidth: 1.5)
        )
    }

    // 说明卡
    private var explainCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("系统指令 vs 开发者指令", systemImage: "info.circle.fill")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.tmCyan)
            Text("• 系统指令：App 内置，不可编辑，优先级最高，控制 AI 的基本行为模式")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("• 开发者指令：用户可自建/编辑，作为补充规范")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("• 两者同时生效，系统指令先注入，开发者指令后注入")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.tmCyan.opacity(0.08))
        )
        .padding(.horizontal, 16)
    }
}
