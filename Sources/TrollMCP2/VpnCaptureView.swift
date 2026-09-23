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
            Section(header: SettingSectionHeader(title: "状态")) {
                row("VPN", vpnStatusText)
                row("本地代理", localProxyOn ? "运行中" : "已停止")
                row("根证书", caExists ? "已生成" : "未生成")
                row("抓包记录", "\(logFiles.count) 个文件")
            }

            Section(header: SettingSectionHeader(title: "操作")) {
                Button("连接抓包 VPN") { connectVpn() }
                    .disabled(vpnStatusText == "connected")
                Button("断开 VPN") { VpnManager.shared.stopVpn(); refresh() }
                Button("生成证书（mobileconfig）") { shareCert() }
                Button(localProxyOn ? "停止本地代理" : "启动本地代理") { toggleLocalProxy() }
            }

            Section(header: SettingSectionHeader(title: "使用步骤")) {
                Text("① 生成证书 → 用「文件」App 打开安装描述文件\n② 设置 → 通用 → 关于本机 → 证书信任设置 → 打开完全信任\n③ 连接 VPN（或本地代理 + WiFi 手动代理 127.0.0.1:18180）\n④ 正常使用目标 App，日志写入 Workspace/network_capture/mitm/")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !notice.isEmpty {
                Section(header: SettingSectionHeader(title: "提示")) {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section(header: SettingSectionHeader(title: "最近日志")) {
                if logFiles.isEmpty {
                    Text("暂无")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(logFiles.prefix(10), id: \.self) { f in
                        Text(f).font(.caption2)
                    }
                }
            }
        }
        .navigationTitle("抓包 VPN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundColor(.primary)
            Spacer()
            Text(v).font(.subheadline).foregroundColor(.secondary)
        }
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
        notice = "证书已生成：\(path)\n用「文件」App 打开该文件安装，然后到 证书信任设置 开启完全信任"
        refresh()
        // 弹出系统分享
        if let root = UIApplication.shared.windows.first?.rootViewController {
            let url = URL(fileURLWithPath: path)
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            root.present(av, animated: true)
        }
    }
}
