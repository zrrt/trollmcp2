import SwiftUI
import Combine

// v2.9.39：内置浏览器悬浮窗状态管理
// - 悬浮在 RootView 之上（所有聊天界面之上），可拖动、可缩小为右侧边缘胶囊、可关闭
// - AI 调用 browser.* 工具时自动 show()，用户实时看到 AI 在页面上做什么
final class FloatingBrowser: ObservableObject {
    static let shared = FloatingBrowser()

    @Published var isVisible = false        // 悬浮窗是否显示
    @Published var isCollapsed = false      // 是否缩小为右侧胶囊
    @Published var center: CGPoint          // 悬浮窗中心（屏幕坐标）

    private var dragStart: CGPoint = .zero
    private var lastExpandedCenter: CGPoint = .zero
    // v2.9.98：悬浮窗位置记忆（重启后恢复到上次位置）
    private let posKey = "floating_browser_center"

    private init() {
        let s = UIScreen.main.bounds
        var x = s.width * 0.55
        var y = s.height * 0.40
        if let saved = UserDefaults.standard.string(forKey: posKey) {
            let parts = saved.split(separator: ",")
            if parts.count == 2, let px = Double(parts[0]), let py = Double(parts[1]) {
                x = CGFloat(px); y = CGFloat(py)
                x = min(max(x, s.width * 0.10), s.width * 0.90)
                y = min(max(y, s.height * 0.15), s.height * 0.85)
            }
        }
        center = CGPoint(x: x, y: y)
    }

    private func persistCenter() {
        UserDefaults.standard.set("\(center.x),\(center.y)", forKey: posKey)
    }

    private var screen: CGSize { UIScreen.main.bounds.size }

    // v2.9.43：胶囊半露悬浮球——中心贴在屏幕右缘，右半圆裁到屏外，露出左半圆可点击
    private var capsuleX: CGFloat { screen.width }

    /// AI 操作 / 用户打开：显示并展开（自动浮现，用户可看到 AI 操作）
    func show() {
        DispatchQueue.main.async {
            self.isVisible = true
            self.isCollapsed = false
        }
    }

    /// 完全隐藏（关闭悬浮窗，仅主线程 UI 调用）
    func hide() {
        isVisible = false
    }

    /// 缩小为右侧边缘胶囊（仅主线程 UI 调用）
    func collapse() {
        lastExpandedCenter = center
        isCollapsed = true
        center = CGPoint(x: capsuleX, y: center.y)
    }

    /// 从胶囊展开回浏览器（仅主线程 UI 调用）
    func expand() {
        if lastExpandedCenter != .zero {
            center = lastExpandedCenter
        }
        isCollapsed = false
    }

    /// v2.9.80：直接设置中心（全屏切换时居中）
    func setCenter(_ p: CGPoint) {
        center = p
    }

    // MARK: - 拖动（由视图 DragGesture 调用）

    func beginDrag() {
        dragStart = center
    }

    func drag(by delta: CGSize) {
        if isCollapsed {
            // 缩小态：x 固定贴右缘，仅上下移动
            center = CGPoint(x: capsuleX, y: dragStart.y + delta.height)
        } else {
            center = CGPoint(x: dragStart.x + delta.width, y: dragStart.y + delta.height)
        }
    }

    func endDrag() {
        if isCollapsed {
            // 缩小态：贴右缘，y 夹在屏幕内
            center.x = capsuleX
            center.y = min(max(center.y, 60), screen.height - 60)
            persistCenter()
        } else {
            // 展开态：拖到屏幕右侧边缘附近 → 自动缩成胶囊；否则夹在屏幕内
            if center.x > screen.width * 0.82 {
                lastExpandedCenter = center
                isCollapsed = true
                center.x = capsuleX
            } else {
                let halfW = screen.width * 0.46
                let halfH = screen.height * 0.30
                center.x = min(max(center.x, halfW), screen.width - halfW)
                center.y = min(max(center.y, halfH), screen.height - halfH)
                persistCenter()
            }
        }
    }
}
