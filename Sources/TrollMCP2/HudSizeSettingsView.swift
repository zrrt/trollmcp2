//
//  HudSizeSettingsView.swift
//  TrollAgent
//
//  v6.0.7：桌面悬浮小女孩尺寸设置——Slider 调整并写入 UserDefaults（trollagent.hud_size），
//  由 HUDManager.start() 以 -size N 传给 HUD 进程生效（修改后重启桌面悬浮生效）。
//

import SwiftUI

struct HudSizeSettingsView: View {
    @State private var size: Double = {
        let v = UserDefaults.standard.double(forKey: "trollagent.hud_size")
        return (v >= 50 && v <= 400) ? v : 150
    }()

    var body: some View {
        VStack(spacing: 16) {
            Slider(value: $size, in: 80...300, step: 5) { editing in
                // v6.0.7：拖动结束后保存并自动重启悬浮，让新尺寸立即生效
                if !editing {
                    UserDefaults.standard.set(size, forKey: "trollagent.hud_size")
                    _ = HUDManager.shared.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        _ = HUDManager.shared.start()
                    }
                }
            }
            .padding(.horizontal)

            Text("\(Int(size)) pt")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.pink)

            Text("调整后自动重启悬浮，新尺寸立即生效")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(.top, 24)
        .navigationTitle("悬浮尺寸")
        .navigationBarTitleDisplayMode(.inline)
    }
}
