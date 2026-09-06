import SwiftUI

/// v2.8.4：网络兼容日志视图
/// 展示 OpenAIClient 自适应降级的过程记录，以及每个模型配置当前记忆的兼容级别。
/// 排查中转站 "Invalid request parameter" 类问题时，先看这里。
/// v2.9.77：界面美化——PageHeader + 卡片化
struct NetworkDebugView: View {
    @ObservedObject private var log = NetworkLog.shared
    @ObservedObject private var models = ModelStore.shared

    private func levelName(_ level: Int) -> String {
        switch level {
        case 0: return "完整载荷"
        case 1: return "互换token参数名"
        case 2: return "去掉tool_choice"
        case 3: return "去掉tools纯对话"
        case 4: return "最小载荷"
        case 5: return "Responses API+工具"
        default: return "未知(\(level))"
        }
    }

    var body: some View {
        PageContainer {
            PageHeader(
                icon: "network",
                title: L10n.t("page_netlog"),
                subtitle: L10n.t("page_netlog_sub"),
                colors: [.orange, .tmBrown]
            )

            // 兼容级别说明
            CardSectionHeader(icon: "list.number", title: "兼容级别说明", color: .orange)
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("App 会在请求被中转站拒绝或超时时自动逐级简化请求参数（降级），成功后记住可用级别。级别 5 走 Responses API（Codex 同款端点），可保留工具调用；级别 ≥3 表示仅可纯对话。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach([0, 1, 2, 5, 3, 4], id: \.self) { lv in
                        HStack {
                            Text("级别 \(lv)")
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(6)
                            Spacer()
                            Text(levelName(lv))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // 各模型当前级别
            CardSectionHeader(icon: "memorychip", title: "各模型当前级别")
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    if models.configs.isEmpty {
                        Text(L10n.t("home_empty_title"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(models.configs) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("\(c.model)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("L\(c.compatLevel) · \(levelName(c.compatLevel))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(c.compatLevel >= 3 && c.compatLevel != 5 ? .orange : .green)
                        }
                        .padding(.vertical, 2)
                    }
                    Divider()
                    Button(action: resetLevels) {
                        HStack {
                            Spacer()
                            Label("重置全部兼容级别（重新从完整载荷试探）", systemImage: "arrow.counterclockwise")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Spacer()
                        }
                    }
                }
            }

            // 最近请求日志
            CardSectionHeader(icon: "clock.arrow.circlepath", title: "最近请求日志")
            CardBox {
                VStack(alignment: .leading, spacing: 6) {
                    if log.entries.isEmpty {
                        Text("暂无记录。发起一次对话后，这里会显示每次请求的载荷级别与结果。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(log.entries.indices, id: \.self) { i in
                        Text(log.entries[i])
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(log.entries[i].contains("失败") ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("page_netlog"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resetLevels() {
        for i in models.configs.indices {
            models.configs[i].compatLevel = 0
        }
        models.save()
        NetworkLog.shared.log("已手动重置全部兼容级别")
    }
}
