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

    private init() {
        let s = UIScreen.main.bounds
        center = CGPoint(x: s.width * 0.55, y: s.height * 0.40)
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
            }
        }
    }
}
