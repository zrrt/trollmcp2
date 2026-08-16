import SwiftUI

struct GatewayView: View {
    @ObservedObject private var gateway = GatewayClient.shared
    @State private var urlInput = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务端")) {
                    TextField("WebSocket URL", text: $urlInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    HStack {
                        Button(gateway.isConnected ? "断开" : "连接") {
                            if gateway.isConnected {
                                gateway.disconnect()
                            } else {
                                gateway.connect(url: urlInput)
                            }
                        }
                        .disabled(urlInput.isEmpty && !gateway.isConnected)
                    }
                }
                Section(header: Text("状态")) {
                    LabeledRow(label: "连接", value: gateway.isConnected ? "已连接 ✅" : "未连接 ❌")
                    LabeledRow(label: "URL", value: gateway.serverURL.isEmpty ? "(未设置)" : gateway.serverURL)
                    if let err = gateway.lastError {
                        LabeledRow(label: "错误", value: err)
                    }
                }
                Section(header: Text("说明")) {
                    Text("Gateway 服务端运行在 Mac/Linux/NAS 上，通过 WebSocket 配对。连接后可远程调用手机工具、下发定时任务。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("网关")
            .onAppear { urlInput = gateway.serverURL }
        }
        .navigationViewStyle(.stack)
    }
}

struct AutomationView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("自动化任务")) {
                    Text("暂无运行中的任务")
                        .foregroundColor(.secondary)
                }
                Section(header: Text("说明")) {
                    Text("自动化中心支持脚本执行、定时任务（cron）、事件触发。通过 MCP 工具 automation.* 和 cron.fire 驱动。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("自动化")
        }
        .navigationViewStyle(.stack)
    }
}
