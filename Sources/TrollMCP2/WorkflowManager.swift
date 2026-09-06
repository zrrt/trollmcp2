import Foundation
import SwiftUI

// v2.9.72：工作流可视化管理器
// AI 调用工具时记录步骤，聊天界面下方显示步骤条

final class WorkflowManager: ObservableObject {
    static let shared = WorkflowManager()

    struct Step: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let tool: String
        var status: Status // pending/running/success/failed/skipped
        var detail: String
        var startTime: Date?
        var endTime: Date?

        enum Status: String {
            case pending, running, success, failed, skipped
        }
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isActive = false
    private var currentRunId: String?

    func startRun(_ name: String) {
        DispatchQueue.main.async {
            self.steps = [Step(name: name, tool: "session", status: .running, detail: "开始执行")]
            self.isActive = true
            self.currentRunId = UUID().uuidString
        }
    }

    func addStep(name: String, tool: String) {
        DispatchQueue.main.async {
            // 标记上一个 running 为 success
            if let idx = self.steps.lastIndex(where: { $0.status == .running }) {
                self.steps[idx].status = .success
                self.steps[idx].endTime = Date()
            }
            self.steps.append(Step(name: name, tool: tool, status: .running, detail: "", startTime: Date()))
        }
    }

    func updateStep(tool: String, detail: String, success: Bool) {
        DispatchQueue.main.async {
            if let idx = self.steps.lastIndex(where: { $0.tool == tool && $0.status == .running }) {
                self.steps[idx].status = success ? .success : .failed
                self.steps[idx].detail = detail
                self.steps[idx].endTime = Date()
            }
        }
    }

    func finishRun(success: Bool) {
        DispatchQueue.main.async {
            // 标记所有 running 为最终状态
            for i in 0..<self.steps.count {
                if self.steps[i].status == .running {
                    self.steps[i].status = success ? .success : .failed
                    self.steps[i].endTime = Date()
                }
            }
            // 3 秒后隐藏
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.isActive = false
            }
        }
    }

    func reset() {
        DispatchQueue.main.async {
            self.steps = []
            self.isActive = false
            self.currentRunId = nil
        }
    }
}

// MARK: - 工作流步骤条 UI

struct WorkflowProgressView: View {
    @ObservedObject private var manager = WorkflowManager.shared

    var body: some View {
        if manager.isActive && !manager.steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(manager.steps.enumerated()), id: \.element.id) { idx, step in
                            stepChip(step, index: idx)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                if let current = manager.steps.last(where: { $0.status == .running }) {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(current.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !current.detail.isEmpty {
                            Text("— \(current.detail)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 6)
            .background(Color(.systemGray6).opacity(0.5))
        }
    }

    private func stepChip(_ step: WorkflowManager.Step, index: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconFor(step.status))
                .font(.system(size: 10))
                .foregroundColor(colorFor(step.status))
            Text(step.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(colorFor(step.status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(colorFor(step.status).opacity(0.1))
        )
    }

    private func iconFor(_ status: WorkflowManager.Step.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "circle.dotted"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func colorFor(_ status: WorkflowManager.Step.Status) -> Color {
        switch status {
        case .pending: return .gray
        case .running: return .blue
        case .success: return .green
        case .failed: return .red
        case .skipped: return .gray
        }
    }
}
