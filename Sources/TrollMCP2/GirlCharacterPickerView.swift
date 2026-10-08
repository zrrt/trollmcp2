import SwiftUI
import UIKit

/// v4.5.1：可爱助手角色选择页——显示小萝莉/御姐兔女郎两个角色卡片（带形象图），点选即切换
/// 入口：设置 → 可爱助手 → 可爱助手角色
struct GirlCharacterPickerView: View {
    @ObservedObject private var companion = GirlCompanion.shared

    var body: some View {
        Form {
            Section(header: Text("选择可爱助手的角色")) {
                ForEach(GirlCharacter.allCases) { c in
                    Button {
                        companion.selectedCharacter = c
                        // v6.0.7：桌面悬浮 HUD 读当前角色，切换后重启悬浮让新角色生效
                        _ = HUDManager.shared.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            _ = HUDManager.shared.start()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            // 角色形象（idle 帧）
                            if let img = UIImage(named: "\(c.iconPrefix)_idle") {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 46, height: 69)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.pink.opacity(0.15))
                                    .frame(width: 46, height: 69)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.rawValue)
                                    .font(.headline)
                                Text(c == .loli ? "粉粉洛丽塔小萝莉" : "黑丝高马尾御姐兔女郎")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if companion.selectedCharacter == c {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.pink)
                            } else {
                                Image(systemName: "circle")
                                    .font(.title2)
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            Section(footer: Text("切换后自动重启桌面悬浮，显示所选角色。")) {
                EmptyView()
            }
        }
        .navigationTitle("可爱助手角色")
        .navigationBarTitleDisplayMode(.inline)
    }
}
