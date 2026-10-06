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
    @ObservedObject private var voice = GirlVoice.shared

    @State private var expression: GirlExpression = .idle
    @State private var breathing = false      // 呼吸（scale 缓动）
    @State private var floating = false       // 浮动（上下轻飘）
    @State private var tapFlash: Int = 0      // 点击触发随机表情的计时
    @State private var deniedHint = false     // 权限被拒提示

    private let frameHeight: CGFloat = 148    // 全身立绘显示高度（右下角悬浮，不宜过大）

    var body: some View {
        VStack(spacing: 6) {
            // 小女孩本体
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
                } else {
                    Circle().fill(Color.pink.opacity(0.25)).frame(width: 60, height: 60)
                }
            }
            .onAppear {
                breathing = true
                floating = true
                voice.onFinalText = { [self] text in self.askAI(text) }
                voice.onPermissionDenied = { [self] in self.deniedHint = true }
            }

            // 说话按钮（麦克风）
            micButton
        }
        .onReceive(tts.$isSpeaking) { speaking in
            withAnimation(.easeInOut(duration: 0.25)) {
                expression = speaking ? .talk : (voice.isListening ? .talk : .idle)
            }
        }
        .onReceive(voice.$isListening) { listening in
            withAnimation(.easeInOut(duration: 0.25)) {
                if listening { expression = .talk }
            }
        }
        .onReceive(Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()) { _ in
            if tapFlash > 0 {
                tapFlash -= 1
                if tapFlash == 0 { expression = .idle }
            }
        }
        .alert("可爱小女孩助手", isPresented: $deniedHint) {
            Button("好", role: .cancel) {}
        } message: {
            Text("需要麦克风 + 语音识别权限才能跟我说话，请在系统设置里允许。")
        }
    }

    // MARK: - 麦克风说话按钮

    private var micButton: some View {
        Button(action: toggleMic) {
            HStack(spacing: 5) {
                if voice.isListening {
                    // 录音中：红点脉冲 + "听你说"
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .scaleEffect(voice.isListening ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: voice.isListening)
                    Text("听你说…")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("说话")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(voice.isListening ? Color.red.opacity(0.85) : Color.pink.opacity(0.75))
            )
            .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 3)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 交互

    /// 点击切表情：随机 开心/思考，短暂后回待机
    private func reactToTap() {
        let r = Int.random(in: 0...1)
        withAnimation(.easeInOut(duration: 0.25)) {
            expression = r == 0 ? .happy : .think
        }
        tapFlash = 2   // 约 1.6s 后回待机
    }

    /// 麦克风：开始听 / 停止发送
    private func toggleMic() {
        if voice.isListening {
            voice.stop()
        } else {
            voice.start()
        }
    }

    /// 识别到文本 → 发 AI（复用聊天发送链路，回复自动流式显示 + 朗读 → 口型帧）
    private func askAI(_ text: String) {
        guard let cfg = ModelStore.shared.defaultConfig else { return }
        // 语音对话需要听到回复 → 若喇叭关着自动打开
        if !tts.speakerEnabled {
            tts.speakerEnabled = true
        }
        let store = ConversationStore.shared
        if store.selectedId == nil {
            store.newConversation()
        }
        store.send(text, using: cfg, reasoningLevel: 3, smartSearch: true)
    }
}
