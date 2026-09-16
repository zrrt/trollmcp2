import SwiftUI

// v2.9.139：AI 控制任意 App 的控制会话状态
// 三段式：执行前(计划) → 执行中(步骤状态+日志+横幅) → 执行后(结果+截图证据)

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

final class ControlSession: ObservableObject {
    static let shared = ControlSession()
    @Published var isActive = false
    @Published var targetApp = ""
    @Published var targetBundleId = ""
    @Published var steps: [ControlStep] = []
    @Published var logs: [String] = []
    @Published var finalResult: String?
    @Published var lastScreenshotPath: String?

    func begin(target: String, bundleId: String = "", plan: [String]) {
        targetApp = target
        targetBundleId = bundleId
        steps = plan.map { ControlStep(title: $0) }
        logs = ["[控制开始] 目标: \(target)\(bundleId.isEmpty ? "" : " (\(bundleId))")，计划 \(plan.count) 步"]
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
        addLog("步骤\(index + 1) \(status.rawValue): \(steps[index].title)\(detail.isEmpty ? "" : " · \(detail)")")
    }

    func addLog(_ line: String) {
        logs.append("[\(Self.ts())] \(line)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    func finish(result: String) {
        finalResult = result
        addLog("[控制结束] \(result)")
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

    private static func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
