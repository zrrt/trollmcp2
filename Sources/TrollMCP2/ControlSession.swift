import SwiftUI

// v2.9.139：AI 控制任意 App 的控制会话状态
// 三段式：执行前(计划) → 执行中(思考流+步骤状态+横幅) → 执行后(结果+截图证据)
// v2.9.140：日志结构化——AI 决策过程可视化（think/action/result/info 四类）

struct ControlStep: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var status: StepStatus = .pending
    var detail: String = ""

    enum StepStatus: String {
        case pending, running, done, failed
        var icon: String {
            switch self {
            case .pending: return "circle"
            case .running: return "arrow.triangle.2.circlepath"
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }
        var color: Color {
            switch self {
            case .pending: return .secondary
            case .running: return .blue
            case .done: return .green
            case .failed: return .red
            }
        }
    }
}

// 思考流日志行：think=AI 判断理由 / action=工具执行 / result=结果反馈 / info=系统信息
struct ControlLog: Identifiable, Equatable {
    let id = UUID()
    enum Kind: String { case think, action, result, info }
    let kind: Kind
    let text: String
}

final class ControlSession: ObservableObject {
    static let shared = ControlSession()
    @Published var isActive = false
    @Published var targetApp = ""
    @Published var targetBundleId = ""
    @Published var steps: [ControlStep] = []
    @Published var logs: [ControlLog] = []
    @Published var finalResult: String?
    @Published var lastScreenshotPath: String?

    func begin(target: String, bundleId: String = "", plan: [String]) {
        targetApp = target
        targetBundleId = bundleId
        steps = plan.map { ControlStep(title: $0) }
        logs = [ControlLog(kind: .info, text: "控制开始 · 目标: \(target)\(bundleId.isEmpty ? "" : " (\(bundleId))") · 计划 \(plan.count) 步")]
        finalResult = nil
        lastScreenshotPath = nil
        isActive = true
        // 同步到 UI 状态（RootView fullScreenCover）
        AppUIState.shared.controlPresented = true
    }

    func updateStep(index: Int, status: ControlStep.StepStatus, detail: String) {
        guard index >= 0 && index < steps.count else { return }
        steps[index].status = status
        steps[index].detail = detail
        addLog(.info, "步骤\(index + 1) \(status.rawValue): \(steps[index].title)\(detail.isEmpty ? "" : " · \(detail)")")
    }

    /// AI 判断理由（思考流，来自工具调用的 reason 参数）
    func addThink(_ text: String) {
        guard !text.isEmpty else { return }
        addLog(.think, text)
    }

    /// 工具执行（AI 调用了哪个工具、参数摘要）
    func addAction(_ text: String) {
        addLog(.action, text)
    }

    /// 结果反馈
    func addResult(_ text: String) {
        addLog(.result, text)
    }

    func addLog(_ kind: ControlLog.Kind, _ line: String) {
        logs.append(ControlLog(kind: kind, text: line))
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }

    func finish(result: String) {
        finalResult = result
        addLog(.info, "控制结束: \(result)")
        isActive = false
    }

    func reset() {
        isActive = false
        targetApp = ""
        targetBundleId = ""
        steps = []
        logs = []
        finalResult = nil
        lastScreenshotPath = nil
    }
}
