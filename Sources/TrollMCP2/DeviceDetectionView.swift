import SwiftUI

struct DeviceDetectionView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var report: DeviceProbe.Report?
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let r = report {
                    // 顶部状态卡片
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(
                                gradient: Gradient(colors: r.ready
                                    ? [Color(red: 0.15, green: 0.65, blue: 0.4), Color(red: 0.1, green: 0.5, blue: 0.35)]
                                    : [Color(red: 0.85, green: 0.3, blue: 0.3), Color(red: 0.7, green: 0.2, blue: 0.25)]),
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                        VStack(spacing: 8) {
                            Image(systemName: r.ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.white)
                            Text(r.ready ? "本机环境就绪" : "本机环境异常")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            Text("\(r.deviceName) · iOS \(r.systemVersion)")
                                .font(.subheadline)
                                .foregroundColor(Color.white.opacity(0.85))
                            Text(r.model)
                                .font(.caption)
                                .foregroundColor(Color.white.opacity(0.7))
                        }
                        .padding(.vertical, 24)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // 环境自检卡片
                    VStack(alignment: .leading, spacing: 0) {
                        Text("环境自检")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 8)

                        ForEach(r.checks) { check in
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(check.infoOnly
                                            ? Color.blue.opacity(0.15)
                                            : (check.passed ? Color.green.opacity(0.15) : Color.red.opacity(0.15)))
                                        .frame(width: 32, height: 32)
                                    Image(systemName: check.infoOnly
                                        ? "info.circle.fill"
                                        : (check.passed ? "checkmark" : "xmark"))
                                        .font(.system(size: check.infoOnly ? 16 : 14, weight: .bold))
                                        .foregroundColor(check.infoOnly
                                            ? .blue
                                            : (check.passed ? .green : .red))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(check.label)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(check.detail)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider().padding(.leading, 60)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // 设备信息卡片（v2.9.67 增强）
                    VStack(spacing: 12) {
                        HStack {
                            Label("设备型号", systemImage: "iphone")
                                .font(.subheadline)
                            Spacer()
                            Text("\(r.deviceModelName)（\(r.deviceModelIdentifier)）")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("系统版本", systemImage: "gear")
                                .font(.subheadline)
                            Spacer()
                            Text("iOS \(r.systemVersion)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("存储空间", systemImage: "internaldrive")
                                .font(.subheadline)
                            Spacer()
                            Text("可用 \(r.storageFree) / 总 \(r.storageTotal)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("内存", systemImage: "memorychip")
                                .font(.subheadline)
                            Spacer()
                            Text(r.memoryTotal)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("屏幕分辨率", systemImage: "rectangle")
                                .font(.subheadline)
                            Spacer()
                            Text(r.screenSize)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("已安装应用", systemImage: "square.grid.2x2")
                                .font(.subheadline)
                            Spacer()
                            Text("\(r.appCount) 个")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("工作区占用", systemImage: "folder")
                                .font(.subheadline)
                            Spacer()
                            Text(r.workspaceSize)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("电池电量", systemImage: "battery.100")
                                .font(.subheadline)
                            Spacer()
                            Text(r.batteryLevel)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("设备名称", systemImage: "info.circle")
                                .font(.subheadline)
                            Spacer()
                            Text(r.deviceName)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // 结论卡片
                    VStack(spacing: 12) {
                        HStack {
                            Label("amfid 绕过", systemImage: "lock.shield")
                                .font(.subheadline)
                            Spacer()
                            Text(r.amfidBypassInferred ? "推断生效" : "未知/未生效")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Label("设备标识符", systemImage: "number")
                                .font(.subheadline)
                            Spacer()
                            Text(r.vendorID)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // 重新检测按钮
                    Button(action: runProbe) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("重新检测")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                } else {
                    // 加载中
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .padding(.top, 80)
                        Text("正在检测本机环境…")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("本机环境")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { presentationMode.wrappedValue.dismiss() }
            }
        }
        .onAppear(perform: runProbe)
    }

    private func runProbe() {
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DeviceProbe.shared.run()
            DispatchQueue.main.async {
                self.report = r
                self.running = false
            }
        }
    }
}
