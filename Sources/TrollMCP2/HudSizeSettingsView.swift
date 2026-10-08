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
            Slider(value: $size, in: 80...300, step: 5) { _ in
                UserDefaults.standard.set(size, forKey: "trollagent.hud_size")
            }
            .padding(.horizontal)

            Text("\(Int(size)) pt")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.pink)

            Text("调整桌面悬浮小女孩的大小\n修改后请在「可爱助手」开关处关闭再打开悬浮生效")
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
