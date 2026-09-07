import SwiftUI

// MARK: - v2.9.89 应用指南（借鉴 Fuck 巨魔工具箱的 AI 逆向引导流程）
// 7 步：前置准备 → 选择应用 → AI 分析 → 应用建议 → 编辑 Hook → 注入生效 → 验证效果

struct GuideView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let steps: [(icon: String, title: String, desc: String)] = [
        ("checkmark.shield.fill", "前置准备",
         "TrollStore 开启「编辑 Entitlements」后卸载重装本 App；在「模型 API」配置好可用模型；用 device.probe 确认环境就绪。"),
        ("square.grid.2x2.fill", "选择应用",
         "在「注入与自动化」选择目标 App，或让 AI 用 injection.list 按名称搜索；敏感应用（微信/支付宝/银行）会提示风险。"),
        ("brain.head.profile.fill", "AI 分析",
         "用 injection.diagnose 检查：root 权限、Bundle 可写、可注入 Mach-O 列表、加密状态、架构匹配——AI 会给出可行性结论。"),
        ("lightbulb.fill", "应用建议",
         "AI 根据分析结果建议：注入目标（Frameworks 内未加密 Mach-O）、dylib 路径、风险等级与预期效果。"),
        ("pencil.and.outline", "编辑 Hook",
         "需要自定义时，用 project.generate_tweak 生成 Tweak 工程 → 线上编译（build-tweak）→ artifact.find 定位 .dylib 产物。"),
        ("syringe.fill", "注入生效",
         "injection.enable 自动完成：杀进程 → 备份 .troll-fools.bak → 伪签 → insert_dylib → 重签 → 验证。失败自动回滚。"),
        ("checkmark.seal.fill", "验证效果",
         "启动目标 App → app.status 检查进程 → injection.inspect 确认加载 → 观察 hook 是否触发；结果记录到兼容矩阵。"),
    ]

    private let notes: [(icon: String, text: String)] = [
        ("key.fill", "必须先在「模型 API」配置可用模型，AI 分析才可运行；分析不 100% 成功时换模型重试。"),
        ("exclamationmark.triangle.fill", "注入只改 Frameworks 内未加密 Mach-O，不碰主二进制；App Store 加密应用会直接提示不可注入。"),
        ("heart.fill", "注入后 App 打不开 → 立即用 injection.restore / rescue.recover_all 恢复，不要卸载重装（会丢数据）。"),
        ("arrow.clockwise.circle.fill", "每次覆盖安装后重新开启「编辑 Entitlements」并卸载重装，权限才会重新应用。"),
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: colorScheme == .dark
                           ? [Color(red: 0.09, green: 0.11, blue: 0.16), Color(red: 0.12, green: 0.14, blue: 0.20)]
                           : [Color(red: 0.90, green: 0.94, blue: 1.0), .white],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 头部
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 72, height: 72)
                            Image(systemName: "book.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Text("TrollAgent 应用指南")
                            .font(.title2.bold())
                        Text("一句话描述目标，AI 自动完成诊断、操作、验证和报告")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                    // 7 步流程
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(LinearGradient(colors: [Color.tmCyan.opacity(0.25), Color.blue.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 44, height: 44)
                                Image(systemName: step.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("\(index + 1)")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Circle().fill(Color.blue))
                                    Text(step.title)
                                        .font(.headline)
                                }
                                Text(step.desc)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.85))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(colorScheme == .dark ? 0.25 : 0.12), lineWidth: 1))
                        )
                    }

                    // 注意事项
                    Text("注意事项")
                        .font(.headline)
                        .padding(.top, 6)
                    ForEach(notes, id: \.text) { note in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: note.icon)
                                .foregroundColor(.orange)
                                .font(.system(size: 15))
                            Text(note.text)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.orange.opacity(0.07))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.15), lineWidth: 1))
                        )
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(L10n.t("row_guide"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
