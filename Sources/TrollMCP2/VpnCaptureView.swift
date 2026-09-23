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
                Text("① 生成证书 → 自动用 Safari 打开 → 点「允许」下载描述文件\n② 设置 → 已下载描述文件 → 安装\n③ 设置 → 通用 → 关于本机 → 证书信任设置 → 打开完全信任\n④ 连接 VPN（或本地代理 + WiFi 手动代理 127.0.0.1:18180）\n⑤ 正常使用目标 App，日志写入 Workspace/network_capture/mitm/")
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
