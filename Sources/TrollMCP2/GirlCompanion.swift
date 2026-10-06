import SwiftUI
import UIKit
import Combine

// MARK: - 可爱小女孩助手 · 状态

/// v4.5.0：可爱小女孩助手全局开关（设置里可选开/关，UserDefaults 持久化）
final class GirlCompanion: ObservableObject {
    static let shared = GirlCompanion()
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "trollmcp2.girl_companion_enabled") }
    }
    private init() {
        enabled = UserDefaults.standard.bool(forKey: "trollmcp2.girl_companion_enabled")
    }
}

// MARK: - 表情帧（对应 Resources/girl_*.png，build-ipa.sh 打进 App 根，Bundle.main 读）

enum GirlExpression: String {
    case idle = "girl_idle"    // 正常/待机
    case happy = "girl_happy"  // 开心（点击）
    case think = "girl_think"  // 思考
    case talk = "girl_talk"    // 说话口型（语音时）
}

// MARK: - 小女孩视图

struct GirlCompanionView: View {
    @ObservedObject private var companion = GirlCompanion.shared
    @ObservedObject private var tts = TTSService.shared

    @State private var expression: GirlExpression = .idle
    @State private var breathing = false      // 呼吸（scale 缓动）
    @State private var floating = false       // 浮动（上下轻飘）
    @State private var tapFlash: Int = 0      // 点击触发随机表情的计时

    private let frameHeight: CGFloat = 152    // 全身立绘显示高度（右下角悬浮，不宜过大）

    var body: some View {
        Group {
            if let img = UIImage(named: expression.rawValue) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: frameHeight)
                    .scaleEffect(breathing ? 1.03 : 0.99)
                    .offset(y: floating ? -7 : 7)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: breathing)
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                    .onTapGesture { reactToTap() }
                    .onAppear {
                        breathing = true
                        floating = true
                    }
            } else {
                // 资源缺失兜底（不影响主功能）
                Circle().fill(Color.pink.opacity(0.25)).frame(width: 60, height: 60)
            }
        }
        .onReceive(tts.$isSpeaking) { speaking in
            withAnimation(.easeInOut(duration: 0.25)) {
                expression = speaking ? .talk : .idle
            }
        }
        .onReceive(Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()) { _ in
            // 点击后的随机表情：短暂展示后回到待机
            if tapFlash > 0 {
                tapFlash -= 1
                if tapFlash == 0 { expression = .idle }
            }
        }
    }

    /// 点击互动：随机切开心/思考，短暂后回待机
    private func reactToTap() {
        let r = Int.random(in: 0...1)
        withAnimation(.easeInOut(duration: 0.25)) {
            expression = r == 0 ? .happy : .think
        }
        tapFlash = 2   // 约 1.6s 后回待机
    }
}
