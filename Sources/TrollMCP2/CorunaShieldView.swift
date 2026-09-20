import SwiftUI

// MARK: - Coruna 安全盾视图（360 风格）
struct CorunaShieldView: View {
    @AppStorage("coruna_shield_enabled") private var shieldEnabled = true
    @AppStorage("coruna_blocked_count") private var blockedCount = 0
    @AppStorage("coruna_last_threat") private var lastThreat: String = ""
    
    // 模拟检测状态：true=安全，false=检测到威胁
    @State private var isSafe = true
    @State private var animateShield = false
    
    private var shieldGradient: LinearGradient {
        if !shieldEnabled {
            return LinearGradient(colors: [.gray, .gray.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return isSafe 
            ? LinearGradient(colors: [Color(red: 0.3, green: 0.9, blue: 0.5), Color(red: 0.1, green: 0.7, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(red: 0.95, green: 0.4, blue: 0.4), Color(red: 0.8, green: 0.2, blue: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    
    var body: some View {
        ZStack {
            // 背景渐变（浅绿亮一点）
            (shieldEnabled 
                ? (isSafe ? LinearGradient(colors: [Color(red: 0.85, green: 0.98, blue: 0.9), Color(red: 0.7, green: 0.95, blue: 0.8)], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color(red: 0.98, green: 0.85, blue: 0.85), Color(red: 0.95, green: 0.7, blue: 0.7)], startPoint: .top, endPoint: .bottom))
                : LinearGradient(colors: [Color(red: 0.95, green: 0.95, blue: 0.95), Color(red: 0.9, green: 0.9, blue: 0.9)], startPoint: .top, endPoint: .bottom))
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(spacing: 24) {
                    // 顶部大盾牌
                    VStack(spacing: 16) {
                        ZStack {
                            // 外圈光环
                            Circle()
                                .stroke(shieldEnabled ? (isSafe ? Color(red: 0.2, green: 0.7, blue: 0.4) : .red) : .gray, lineWidth: 3)
                                .frame(width: 140, height: 140)
                                .scaleEffect(animateShield ? 1.1 : 1.0)
                                .opacity(animateShield ? 0.3 : 0.6)
                            
                            // 盾牌（用 iOS 16 肯定有的图标）
                            Image(systemName: isSafe ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(shieldGradient)
                                .shadow(color: shieldEnabled ? (isSafe ? .green : .red) : .gray, radius: 20)
                        }
                        .padding(.top, 40)
                        
                        VStack(spacing: 8) {
                            Text(shieldEnabled ? (isSafe ? "防护中" : "检测到威胁") : "防护已关闭")
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundColor(isSafe ? Color(red: 0.1, green: 0.5, blue: 0.3) : .red)
                            
                            Text(shieldEnabled 
                                ? (isSafe ? "正在实时监控恶意网站" : "已拦截可疑访问")
                                : "点击下方开关开启防护")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // 统计卡片
                    HStack(spacing: 16) {
                        StatCard(title: "已拦截", value: "\(blockedCount)", unit: "次", icon: "hand.raised.fill", color: .orange)
                        StatCard(title: "防护状态", value: shieldEnabled ? "ON" : "OFF", unit: "", icon: "shield.fill", color: shieldEnabled ? .green : .gray)
                        StatCard(title: "受影响版本", value: "17.2", unit: "以下", icon: "iphone", color: .blue)
                    }
                    .padding(.horizontal)
                    
                    // 开关按钮
                    Button(action: {
                        withAnimation(.spring()) {
                            shieldEnabled.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: shieldEnabled ? "power.circle.fill" : "power.circle")
                                .font(.title2)
                            Text(shieldEnabled ? "关闭防护" : "开启防护")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(shieldEnabled 
                            ? LinearGradient(colors: [.red.opacity(0.8), .red], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [.green.opacity(0.8), .green], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(16)
                    }
                    .padding(.horizontal)
                    
                    // 防御措施卡片
                    VStack(alignment: .leading, spacing: 16) {
                        Text("防御措施")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal)
                        
                        VStack(spacing: 12) {
                            DefenseRow(icon: "globe", title: "恶意网站检测", desc: "拦截已知 Coruna 利用站点", enabled: shieldEnabled)
                            DefenseRow(icon: "safari", title: "Safari 行为监控", desc: "检测异常进程行为和内存操作", enabled: shieldEnabled)
                            DefenseRow(icon: "doc.text.magnifyingglass", title: "IOC 规则库", desc: "14 个文件哈希 + 6 条网络规则", enabled: shieldEnabled)
                            DefenseRow(icon: "lock.shield", title: "内核防护", desc: "监控 IOSurface 异常调用", enabled: shieldEnabled)
                        }
                        .padding(.horizontal)
                    }
                    
                    // 漏洞说明
                    VStack(alignment: .leading, spacing: 12) {
                        Text("关于 Coruna 漏洞")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "覆盖版本", value: "iOS 13.0 - 17.2.1")
                            InfoRow(label: "漏洞数量", value: "5 条利用链 + 23 个漏洞")
                            InfoRow(label: "攻击方式", value: "网页零点击")
                            InfoRow(label: "你的设备", value: "iOS 16.3 ✅ 受影响")
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                        .padding(.horizontal)
                    }
                    
                    // 底部
                    Text("基于 Google Threat Intelligence IOCs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animateShield = true
            }
        }
    }
}

// MARK: - 统计卡片
struct StatCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 防御措施行
struct DefenseRow: View {
    let icon: String
    let title: String
    let desc: String
    let enabled: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(enabled ? .green : .gray)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(enabled ? .green : .gray)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 信息行
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .fontWeight(.medium)
        }
    }
}
