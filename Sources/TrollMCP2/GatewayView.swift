import SwiftUI

struct GatewayView: View {
    @ObservedObject private var gateway = GatewayClient.shared
    @State private var urlInput = ""

    var body: some View {
        CompatNav {
            Form {
                Section(header: Text(L10n.t("ui_97"))) {
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
                Section(header: Text(L10n.t("ui_110"))) {
                    LabeledRow(label: "连接", value: gateway.isConnected ? "已连接 ✅" : "未连接 ❌")
                    LabeledRow(label: "URL", value: gateway.serverURL.isEmpty ? "(未设置)" : gateway.serverURL)
                    if let err = gateway.lastError {
                        LabeledRow(label: "错误", value: err)
                    }
                }
                Section(header: Text(L10n.t("ui_132"))) {
                    Text(L10n.t("ui_6"))
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
        CompatNav {
            List {
                Section(header: Text(L10n.t("ui_127"))) {
                    Text(L10n.t("ui_94"))
                        .foregroundColor(.secondary)
                }
                Section(header: Text(L10n.t("ui_132"))) {
                    Text(L10n.t("ui_126"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("自动化")
        }
        .navigationViewStyle(.stack)
    }
}
