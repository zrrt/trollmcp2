import SwiftUI

// MARK: - 智能搜索（v2.9.10 / v2.9.77 美化）
// 说明 web.search 工具用法 + 当前会话搜索开关指引。

struct SmartSearchView: View {
    var body: some View {
        PageContainer {
            PageHeader(
                icon: "magnifyingglass.circle.fill",
                title: L10n.t("page_search"),
                subtitle: L10n.t("page_search_sub"),
                colors: [.tmCyan, .blue]
            )

            // 机制
            CardSectionHeader(icon: "gearshape", title: "什么是智能搜索")
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L10n.t("ui_99"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("web.search + web.fetch")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.tmCyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.tmCyan.opacity(0.1))
                            .cornerRadius(6)
                    }
                    Text(L10n.t("ui_11"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 使用方法
            CardSectionHeader(icon: "list.number", title: "使用方法")
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    stepRow(1, "输入栏上方的「智能搜索·开」chip 保持开启")
                    stepRow(2, "提问时注明「请搜索」或直接问时效性问题")
                    stepRow(3, "AI 自动调用 web.search 检索 → 必要时 web.fetch 读原文 → 带引用回答")
                }
            }

            // 示例
            CardSectionHeader(icon: "text.bubble", title: "示例")
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "quote.bubble.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.tmCyan)
                        Text(L10n.t("ui_55"))
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    Text("→ AI 调用 web.search(\"2026 iPhone 发布会\")，再 web.fetch 打开最相关的链接读正文")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // 隐私
            CardSectionHeader(icon: "lock.shield", title: "隐私", color: .orange)
            CardBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                    Text(L10n.t("ui_73"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .navigationTitle(L10n.t("page_search"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stepRow(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(num)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
