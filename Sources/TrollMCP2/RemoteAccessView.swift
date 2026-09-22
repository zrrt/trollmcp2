import SwiftUI

// MARK: - 远程访问总览（SSH 主动连接 + 远程终端被控制）
struct RemoteAccessView: View {
    @AppStorage("ssh.host") private var sshHost: String = ""
    @State private var terminalRunning = RemoteTerminalServer.shared.isRunning

    var body: some View {
        Form {
            Section(header: Text("主动连接"), footer: Text("通过 SSH 连接到远程 Linux 服务器执行命令")) {
                NavigationLink(destination: SSHSettingsView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.forward.circle.fill")
                            .font(.title2)
                            .foregroundColor(.tmCyan)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SSH 远程连接")
                                .foregroundColor(.primary)
                            Text(sshHost.isEmpty ? "未配置" : sshHost)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section(header: Text("被远程控制"), footer: Text("TrollAgent 开启 HTTP API，云端/远程可直接调用工具、读审计、查崩溃")) {
                NavigationLink(destination: RemoteTerminalView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.left.circle.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("远程终端服务")
                                .foregroundColor(.primary)
                            Text(terminalRunning ? "运行中 :\(RemoteTerminalServer.shared.port)" : "未启动")
                                .font(.caption)
                                .foregroundColor(terminalRunning ? .green : .secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("远程访问")
        .onAppear {
            terminalRunning = RemoteTerminalServer.shared.isRunning
        }
    }
}
