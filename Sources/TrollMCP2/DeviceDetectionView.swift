import SwiftUI

struct DeviceDetectionView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var report: DeviceProbe.Report?
    @State private var running = false

    var body: some View {
        List {
            if let r = report {
                Section(header: SettingSectionHeader(title: "设备")) {
                    LabeledRow(label: "名称", value: r.deviceName)
                    LabeledRow(label: "型号", value: r.model)
                    LabeledRow(label: "系统", value: r.systemVersion)
                    LabeledRow(label: "标识符", value: r.vendorID)
                }

                Section(header: SettingSectionHeader(title: "环境自检")) {
                    ForEach(r.checks) { check in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(check.passed ? .green : .red)
                                .font(.system(size: 18))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(check.label)
                                    .font(.body)
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section(header: SettingSectionHeader(title: "结论")) {
                    HStack {
                        Text("本机就绪")
                        Spacer()
                        Text(r.ready ? "是 ✅" : "否 ❌")
                            .foregroundColor(r.ready ? .green : .red)
                            .fontWeight(.medium)
                    }
                    HStack {
                        Text("amfid 绕过")
                        Spacer()
                        Text(r.amfidBypassInferred ? "推断生效" : "未知/未生效")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("重新检测")
                        Spacer()
                        Button(action: runProbe) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.blue)
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("检测中…")
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("本机环境检测")
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
