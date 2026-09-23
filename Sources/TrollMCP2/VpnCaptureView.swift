// VpnCaptureView：MITM 抓包 VPN/代理 控制页（v3.3.0）

import SwiftUI
import NetworkExtension

struct VpnCaptureView: View {
    @State private var vpnStatusText = "unknown"
    @State private var localProxyOn = false
    @State private var caExists = false
    @State private var logFiles: [String] = []
    @State private var notice = ""

    var body: some View {
        List {
            // 主开关（v3.3.2：类似系统设置里的大开关，一键开/关抓包）
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.tmCyan.opacity(0.15))
                            .frame(width: 50, height: 50)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.tmCyan)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("抓包 VPN")
                            .font(.headline)
                        Text(mainSwitchSubtitle())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { vpnActive },
                        set: { on in
                            if on {
                                connectVpn()
                            } else {
                                VpnManager.shared.stopVpn()
                                VpnManager.shared.stopLocalProxy()
                                refresh()
                            }
                        }))
                    .labelsHidden()
                    .tint(.tmCyan)
                }
                .padding(.vertical, 4)
            }

            // 状态概览卡片（两行四块）
            Section {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        statusCard("VPN", vpnStatusText, icon: "network", color: vpnColor)
                        statusCard("本地代理", localProxyOn ? "运行中" : "已停止",
                                   icon: "antenna.radiowaves.left.and.right",
                                   color: localProxyOn ? .orange : .gray)
                    }
                    HStack(spacing: 12) {
                        statusCard("根证书", caExists ? "已生成" : "未生成",
                                   icon: "checkmark.shield.fill",
                                   color: caExists ? .green : .gray)
                        statusCard("抓包记录", "\(logFiles.count) 个文件",
                                   icon: "doc.text.fill",
                                   color: logFiles.isEmpty ? .gray : .blue)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)

            // 操作
            Section(header: SettingSectionHeader(title: "操作")) {
                actionRow("连接抓包 VPN", icon: "network", color: .blue) { connectVpn() }
                    .disabled(vpnStatusText == "connected")
                actionRow("断开 VPN", icon: "stop.circle.fill", color: .red) {
                    VpnManager.shared.stopVpn(); refresh()
                }
                actionRow("生成证书（mobileconfig）", icon: "lock.shield.fill", color: .green) { shareCert() }
                actionRow(localProxyOn ? "停止本地代理" : "启动本地代理",
                          icon: "antenna.radiowaves.left.and.right", color: .orange) { toggleLocalProxy() }
            }

            // 使用步骤
            Section(header: SettingSectionHeader(title: "使用步骤")) {
                stepRow(1, "生成证书", "自动用 Safari 打开下载描述文件")
                stepRow(2, "安装", "设置 → 已下载描述文件 → 安装")
                stepRow(3, "信任", "通用 → 证书信任设置 → 打开完全信任")
                stepRow(4, "连接", "VPN，或本地代理 + WiFi 手动代理 127.0.0.1:18180")
                stepRow(5, "使用", "正常用目标 App，日志写入 Workspace/network_capture/mitm/")
            }

            if !notice.isEmpty {
                Section(header: SettingSectionHeader(title: "提示")) {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // 最近日志
            Section(header: SettingSectionHeader(title: "最近日志")) {
                if logFiles.isEmpty {
                    Text("暂无")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(logFiles.prefix(8), id: \.self) { f in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.plaintext")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(f).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("抓包 VPN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
    }

    // MARK: - 状态卡片 / 操作行 / 步骤行

    private func statusCard(_ title: String, _ value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.12))
        )
    }

    private func actionRow(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(color)
                }
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func stepRow(_ n: Int, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.tmCyan))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var vpnColor: Color {
        switch vpnStatusText {
        case "connected": return .green
        case "connecting": return .orange
        default: return .gray
        }
    }

    /// v3.3.2：主开关状态与副标题
    private var vpnActive: Bool {
        vpnStatusText == "connected" || vpnStatusText == "connecting" || localProxyOn
    }

    private func mainSwitchSubtitle() -> String {
        if vpnStatusText == "connected" { return "已连接 · 系统流量走 MITM 代理" }
        if vpnStatusText == "connecting" { return "正在连接…" }
        if localProxyOn { return "本地代理运行中 · WiFi 手动代理生效" }
        return "未运行 · 打开后自动抓取 HTTPS 明文"
    }

    private func refresh() {
        VpnManager.shared.loadPreferences { _ in
            let raw = VpnManager.shared.vpnStatus.rawValue
            switch raw {
            case 3: vpnStatusText = "connected"
            case 2: vpnStatusText = "connecting"
            default: vpnStatusText = "disconnected"
            }
        }
        localProxyOn = VpnManager.shared.localProxyRunning
        caExists = VpnManager.shared.caExists
        logFiles = ((try? FileManager.default.contentsOfDirectory(atPath: VpnManager.shared.mitmLogDir)) ?? []).sorted().reversed()
    }

    private func connectVpn() {
        VpnManager.shared.startVpn { err in
            if let e = err {
                notice = "VPN 启动失败：\(e)\n可用「本地代理」代替（WiFi 手动代理）"
            } else {
                notice = "VPN 已连接（等待系统弹窗允许）"
            }
            refresh()
        }
    }

    private func toggleLocalProxy() {
        if localProxyOn {
            VpnManager.shared.stopLocalProxy()
        } else {
            _ = VpnManager.shared.startLocalProxy()
            notice = "本地代理已启动：127.0.0.1:18180\n去 设置→WiFi→当前网络→配置代理→手动，填 127.0.0.1 和 18180"
        }
        refresh()
    }

    private func shareCert() {
        guard let path = VpnManager.shared.generateMobileConfig() else {
            notice = "证书生成失败"
            return
        }
        refresh()
        // v3.3.1：用 Safari 打开本地 HTTP 下载 —— 触发系统标准"下载配置描述文件"确认框，
        // 比"存储到文件再打开"更稳（无沙箱环境下文件 App 打开 profile 不弹安装）。
        let dir = (path as NSString).deletingLastPathComponent
        _ = LocalHttpServer.shared.start(rootDir: dir)
        let url = URL(string: "http://127.0.0.1:18080/TrollAgentCA.mobileconfig")!
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                notice = "打开 Safari 失败，请手动用「文件」App 打开：\(path)"
            } else {
                notice = "已在 Safari 打开下载页\n① 点「允许」下载描述文件\n② 到 设置 → 已下载描述文件 → 安装\n③ 设置 → 通用 → 关于本机 → 证书信任设置 → 打开完全信任"
            }
        }
    }
}
