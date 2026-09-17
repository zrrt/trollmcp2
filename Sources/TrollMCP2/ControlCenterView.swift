import SwiftUI

// v2.9.139：AI 控制中心——控制任意 App 时的计划/进度/日志/结果实时页
// 三段式：计划前置（执行前）→ 步骤+日志+横幅（执行中）→ 结果+截图（执行后）

struct ControlCenterView: View {
    @ObservedObject private var session = ControlSession.shared
    @ObservedObject private var ui = AppUIState.shared
    @Environment(\.presentationMode) private var pm

    var body: some View {
        CompatNav {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 头部：目标 + 状态
                    header
                    // 计划步骤
                    if !session.steps.isEmpty {
                        stepsSection
                    }
                    // 执行日志
                    if !session.logs.isEmpty {
                        logsSection
                    }
                    // 结果报告
                    if let r = session.finalResult {
                        resultSection(r)
                    }
                    // 最近截图
                    if let shot = session.lastScreenshotPath {
                        screenshotSection(shot)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.t("ui_172", "AI 控制中心"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("ui_177", "关闭")) {
                        session.reset()
                        ui.controlPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        ui.controlPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: session.isActive ? "target" : "checkmark.seal")
                    .font(.system(size: 22))
                    .foregroundColor(session.isActive ? .blue : .green)
                Text(session.targetApp.isEmpty ? (session.finalResult != nil ? L10n.t("ui_181") : L10n.t("ui_180")) : session.targetApp)
                    .font(.headline)
                Spacer()
                statusBadge
            }
            if !session.targetBundleId.isEmpty {
                Text(session.targetBundleId)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if session.finalResult == nil && !session.isActive && !session.targetApp.isEmpty {
                Text(L10n.t("ui_182"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color)
        if session.isActive {
            text = L10n.t("ui_178")
            color = .blue
        } else if session.finalResult != nil {
            text = L10n.t("ui_179")
            color = .green
        } else {
            text = L10n.t("ui_180")
            color = .secondary
        }
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(8)
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("ui_173", "执行计划"))
                .font(.subheadline.weight(.semibold))
            ForEach(Array(session.steps.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.status.icon)
                        .foregroundColor(step.status.color)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i + 1). \(step.title)")
                            .font(.subheadline)
                            .foregroundColor(step.status == .pending ? .secondary : .primary)
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("ui_174", "执行日志"))
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.logs.suffix(80)) { log in
                    HStack(alignment: .top, spacing: 6) {
                        Text(logIcon(log.kind))
                            .font(.system(size: 11))
                            .foregroundColor(logColor(log.kind))
                        Text(log.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(logColor(log.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
    }

    private func logIcon(_ kind: ControlLog.Kind) -> String {
        switch kind {
        case .think: return "💭"
        case .action: return "🛠"
        case .result: return ""
        case .info: return "ℹ️"
        }
    }

    private func logColor(_ kind: ControlLog.Kind) -> Color {
        switch kind {
        case .think: return .blue
        case .action: return .orange
        case .result: return .primary
        case .info: return .secondary
        }
    }

    private func resultSection(_ r: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("ui_175", "执行结果"))
                .font(.subheadline.weight(.semibold))
            Text(r)
                .font(.subheadline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08))
                .cornerRadius(10)
                .textSelection(.enabled)
        }
    }

    private func screenshotSection(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("ui_176", "现场截图"))
                .font(.subheadline.weight(.semibold))
            if let img = UIImage(contentsOfFile: path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(10)
            } else {
                Text(path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
