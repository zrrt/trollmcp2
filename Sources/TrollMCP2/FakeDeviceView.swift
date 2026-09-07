import SwiftUI

// MARK: - v2.9.90 设备伪装（绿盾式）：选目标 App + 选机型 → 注入 FakeDevice + 写入 fake_device.json

struct DeviceSpec: Codable, Identifiable, Hashable {
    let battery: String
    let cpu: String
    let freq: String
    let inch: String
    let name: String
    let ppi: String
    let resolution: String
    var id: String { name }
}

final class DeviceDatabase {
    static let shared = DeviceDatabase()
    var devices: [(identifier: String, spec: DeviceSpec)] = []
    private init() {
        guard let url = Bundle.main.url(forResource: "devices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return }
        for (id, dict) in raw {
            guard let spec = try? JSONDecoder().decode(DeviceSpec.self, from: JSONSerialization.data(withJSONObject: dict)) else { continue }
            devices.append((identifier: id, spec: spec))
        }
        devices.sort { $0.spec.name < $1.spec.name }
    }
}

struct FakeDeviceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var apps: [AppCatalog.AppEntry] = AppCatalog.list()
    @State private var selectedAppId: String = ""
    @State private var selectedModel: String = ""
    @State private var resultText = ""
    @State private var resultOK = false
    @State private var busy = false

    private var db: DeviceDatabase { DeviceDatabase.shared }
    private var selectedSpec: DeviceSpec? {
        guard let pair = db.devices.first(where: { $0.identifier == selectedModel }) else { return nil }
        return pair.spec
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: colorScheme == .dark
                           ? [Color(red: 0.09, green: 0.11, blue: 0.16), Color(red: 0.12, green: 0.14, blue: 0.20)]
                           : [Color(red: 0.90, green: 0.94, blue: 1.0), .white],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 目标 App
                    VStack(alignment: .leading, spacing: 8) {
                        Text("① 选择目标 App")
                            .font(.headline)
                        Picker("目标 App", selection: $selectedAppId) {
                            Text("请选择").tag("")
                            ForEach(apps, id: \.bundleId) { app in
                                Text("\(app.name) (\(app.bundleId))").tag(app.bundleId)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.9)))
                    }

                    // 机型
                    VStack(alignment: .leading, spacing: 8) {
                        Text("② 选择伪装机型")
                            .font(.headline)
                        Picker("机型", selection: $selectedModel) {
                            Text("请选择").tag("")
                            ForEach(db.devices, id: \.identifier) { pair in
                                Text(pair.spec.name).tag(pair.identifier)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.9)))

                        if let spec = selectedSpec {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(spec.name, systemImage: "iphone")
                                    .font(.subheadline.bold())
                                Text("型号标识 \(selectedModel) · \(spec.inch) · \(spec.resolution) · \(spec.ppi)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(spec.cpu) · \(spec.freq) · \(spec.battery)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
                        }
                    }

                    // 操作（iOS 14 兼容样式：不用 borderedProminent/bordered）
                    HStack(spacing: 12) {
                        Button {
                            apply()
                        } label: {
                            Label("应用伪装", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .foregroundColor(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill((busy || selectedAppId.isEmpty || selectedModel.isEmpty) ? Color.blue.opacity(0.4) : Color.blue)
                        )
                        .disabled(busy || selectedAppId.isEmpty || selectedModel.isEmpty)

                        Button {
                            restore()
                        } label: {
                            Label("还原", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .foregroundColor(.blue)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.blue.opacity(busy || selectedAppId.isEmpty ? 0.12 : 0.15))
                        )
                        .disabled(busy || selectedAppId.isEmpty)
                    }

                    if busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("注入 FakeDevice 并重启 App…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    if !resultText.isEmpty {
                        Text(resultText)
                            .font(.subheadline)
                            .foregroundColor(resultOK ? .green : .red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill((resultOK ? Color.green : Color.red).opacity(0.08)))
                    }

                    Text("原理（v2.9.93）：默认内存注入——App 运行时用 opainject 加载 FakeDevice.dylib，读取 fake_device.json 替换 UIDevice 返回的机型/名称/系统版本。不改任何文件、零残留，App 重启即还原；恢复 = 点还原（杀进程重启）。部分 App 通过 sysctl 读硬件标识，无法被 UIDevice 层覆盖。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(16)
            }
        }
        .navigationTitle("设备伪装")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func apply() {
        guard let pair = db.devices.first(where: { $0.identifier == selectedModel }) else { return }
        busy = true
        resultText = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let params: [String: Any] = [
                "bundle_id": selectedAppId,
                "name": pair.spec.name,
                "model": "iPhone",
                "model_identifier": selectedModel,
                "system_version": "18.0",
                "restart": true
            ]
            do {
                let r = try DeviceFakeTool().invoke(params)
                let status = r["status"] as? String ?? "?"
                let note = r["note"] as? String ?? ""
                DispatchQueue.main.async {
                    busy = false
                    resultOK = status == "faked"
                    resultText = resultOK ? "✅ 伪装已应用：\(note)" : "❌ \(r)"
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    resultOK = false
                    resultText = "❌ 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func restore() {
        busy = true
        resultText = ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try DeviceRestoreTool().invoke(["bundle_id": selectedAppId])
                let status = r["status"] as? String ?? "?"
                DispatchQueue.main.async {
                    busy = false
                    resultOK = status == "restored"
                    resultText = resultOK ? "✅ 已还原真实设备信息" : "❌ \(r)"
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    resultOK = false
                    resultText = "❌ 失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
