import SwiftUI

/// v2.9.180：远程诊断配置页
/// 配置服务器地址 + token + 开关；崩溃自动上报 + 云端指令测试统一走这里。
struct RemoteDiagnosticsView: View {
    @ObservedObject var agent = RemoteAgent.shared
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section(footer: Text("开启后 TrollAgent 每 4 秒向服务器轮询一次指令；同时崩溃日志会在下次启动时自动上报到后台，无需手动复制。")) {
                Toggle("启用远程诊断", isOn: $agent.enabled)
                    .onChange(of: agent.enabled) { _ in agent.save() }
                TextField("服务器地址（https://你的域名:8766）", text: $agent.serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: agent.serverURL) { _ in agent.save() }
                TextField("访问令牌（token）", text: $agent.token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: agent.token) { _ in agent.save() }
            }

            Section(header: Text("设备标识")) {
                HStack {
                    Text("设备 ID")
                    Spacer()
                    Text(agent.deviceID)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Button("复制设备 ID") {
                    UIPasteboard.general.string = agent.deviceID
                    testResult = "已复制"
                }
            }

            Section {
                Button(testing ? "连接中…" : "测试连接") {
                    testConnection()
                }
                .disabled(testing || agent.serverURL.isEmpty || agent.token.isEmpty)
                if let testResult = testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundColor(testResult.hasPrefix("连接成功") || testResult == "已复制" ? .green : .red)
                }
                HStack {
                    Text("已执行远程指令")
                    Spacer()
                    Text("\(agent.executedCount)")
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("安全边界"), footer: Text("远程通道只允许执行只读诊断白名单（设备信息/文件浏览/注入状态/日志查询等）。注入、删除、写入、启动 App、网络抓包等危险操作一律拒绝，绝不支持远程触发。")) {
                Label("只读白名单，无危险操作", systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .navigationTitle("远程诊断")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func testConnection() {
        testing = true
        testResult = nil
        agent.testConnection { ok, msg in
            DispatchQueue.main.async {
                testing = false
                testResult = msg
            }
        }
    }
}
