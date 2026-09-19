import SwiftUI

// MARK: - Coruna 安全盾视图
struct CorunaShieldView: View {
    @AppStorage("coruna_shield_enabled") private var shieldEnabled = true
    @AppStorage("coruna_blocked_count") private var blockedCount = 0
    
    var body: some View {
        CompatNav {
            Form {
                Section(header: Text("防护状态")) {
                    HStack {
                        Image(systemName: shieldEnabled ? "shield.checkered" : "shield.slash")
                            .font(.title)
                            .foregroundColor(shieldEnabled ? .green : .gray)
                        VStack(alignment: .leading) {
                            Text(shieldEnabled ? "安全盾已开启" : "安全盾已关闭")
                                .font(.headline)
                            Text(shieldEnabled ? "正在检测恶意网站" : "未检测威胁")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $shieldEnabled)
                            .labelsHidden()
                    }
                }
                
                Section(header: Text("拦截统计")) {
                    LabeledRow(label: "已拦截恶意网站", value: "\(blockedCount) 次")
                    LabeledRow(label: "受影响版本", value: "iOS 13.0 - 17.2.1")
                    LabeledRow(label: "你的版本", value: "iOS 16.3 ✅ 受影响")
                }
                
                Section(header: Text("Coruna 漏洞说明")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("什么是 Coruna？")
                            .font(.headline)
                        Text("Coruna 是一个 iOS 漏洞利用工具包，覆盖 iOS 13.0 - 17.2.1，包含 5 条完整漏洞利用链 + 23 个独立漏洞。用户只要访问恶意网站，Safari 就会被远程利用，拿到系统权限。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("攻击方式：")
                            .font(.headline)
                            .padding(.top, 8)
                        Text("• 水坑攻击：恶意网站嵌入 iframe\n• 零点击：用户只要访问就触发\n• WebKit 漏洞：类型混淆 → 任意读写\n• 内核漏洞：IOSurface → 内核 R/W\n• PAC 绕过：arm64e 指针认证绕过")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("防御措施")) {
                    LabeledRow(label: "恶意网站检测", value: shieldEnabled ? "✅ 已开启" : "❌ 已关闭")
                    LabeledRow(label: "Safari 异常行为监控", value: shieldEnabled ? "✅ 已开启" : "❌ 已关闭")
                    LabeledRow(label: "已知 IOC 拦截", value: shieldEnabled ? "✅ 已开启" : "❌ 已关闭")
                }
                
                Section(header: Text("关于")) {
                    Text("Coruna 安全盾基于 Google Threat Intelligence 发布的 IOCs（文件哈希、URL、网络规则），检测并拦截 Coruna 漏洞利用。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Coruna 安全盾")
        }
    }
}
