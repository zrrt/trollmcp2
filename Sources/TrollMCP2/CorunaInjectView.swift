import SwiftUI
import UIKit

// MARK: - Coruna Web 注入视图
// v3.0.5: 网页端一键注入 dylib 到任意 App
struct CorunaInjectView: View {
    @ObservedObject private var injector = CorunaWebInjector.shared
    @State private var availableApps: [AppCatalog.AppEntry] = []
    @State private var selectedApp: AppCatalog.AppEntry?
    @State private var availableDylibs: [String] = []
    @State private var selectedDylib: String = ""
    @State private var showAppPicker = false
    @State private var showDylibPicker = false
    @State private var showWebView = false
    @State private var isDeviceCompatible = true
    @State private var showWarning = false

    var body: some View {
        CompatNav {
            ScrollView {
                VStack(spacing: 16) {
                    // 兼容性检查
                    if !isDeviceCompatible {
                        compatibilityWarning
                    }

                    // 状态卡片
                    statusCard

                    // 配置区域
                    configurationSection

                    // 漏洞链说明
                    chainInfoSection

                    // 操作按钮
                    actionButtons
                }
                .padding()
            }
            .navigationTitle("Coruna Web 注入")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                isDeviceCompatible = CorunaWebInjector.isCompatible
                loadApps()
                loadDylibs()
            }
            .sheet(isPresented: $showAppPicker) {
                AppPickerSheet(apps: availableApps, selectedApp: $selectedApp)
            }
            .sheet(isPresented: $showDylibPicker) {
                DylibPickerSheet(dylibs: availableDylibs, selectedDylib: $selectedDylib)
            }
            .sheet(isPresented: $showWebView) {
                CorunaExploitWebView(injector: injector)
            }
            .alert("注意", isPresented: $showWarning) {
                Button("继续", role: .destructive) {
                    startInjection()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此功能将利用 Coruna 漏洞链获取内核权限并注入 dylib 到 \(selectedApp?.name ?? "目标 App")。\n\n仅用于安全研究目的，确保你了解风险。")
            }
        }
    }

    // MARK: - 兼容性警告
    private var compatibilityWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("设备不兼容")
                    .font(.headline)
                    .foregroundColor(.orange)
            }
            Text("Coruna 漏洞链支持 iOS 13.0 - 17.2.1。当前设备: \(CorunaWebInjector.deviceInfo)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - 状态卡片
    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: statusIcon)
                    .font(.title)
                    .foregroundColor(statusColor)
                VStack(alignment: .leading) {
                    Text(injector.currentStage.rawValue)
                        .font(.headline)
                    Text(injector.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // 进度条
            ProgressView(value: injector.stageProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: statusColor))

            // 状态详情
            HStack {
                statusBadge(label: "内核 R/W", active: injector.kernelRWReady)
                statusBadge(label: "Dev Mode", active: injector.developerModeEnabled)
                statusBadge(label: "PAC 绕过", active: injector.stageProgress >= 0.6)
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private var statusIcon: String {
        switch injector.currentStage {
        case .success: return "checkmark.circle.fill"
        case .failed, .crashed: return "xmark.circle.fill"
        case .ready: return "checkmark.shield.fill"
        default: return "shield.lefthalf.filled"
        }
    }

    private var statusColor: Color {
        switch injector.currentStage {
        case .success: return .green
        case .failed, .crashed: return .red
        case .ready: return .blue
        default: return .orange
        }
    }

    private func statusBadge(label: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundColor(active ? .green : .secondary)
        }
    }

    // MARK: - 配置区域
    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("注入配置")
                .font(.headline)

            // 目标 App 选择
            Button(action: { showAppPicker = true }) {
                HStack {
                    Image(systemName: "app.dashed")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text("目标 App")
                            .font(.subheadline)
                        Text(selectedApp?.name ?? "选择要注入的应用")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            // Dylib 选择
            Button(action: { showDylibPicker = true }) {
                HStack {
                    Image(systemName: "square.stack.3d.down.right")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text("Dylib 文件")
                            .font(.subheadline)
                        Text(selectedDylib.isEmpty ? "选择要注入的 dylib" : (selectedDylib as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            // 平台路径选择
            VStack(alignment: .leading, spacing: 8) {
                Text("利用路径")
                    .font(.subheadline)
                Picker("利用路径", selection: $injector.selectedPlatform) {
                    ForEach(CorunaWebInjector.PlatformPath.allCases, id: \.self) { path in
                        Text(path.rawValue).tag(path)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
        }
    }

    // MARK: - 漏洞链信息
    private var chainInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("漏洞利用链")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                chainStep(number: 1, title: "WebKit RCE", desc: "CVE-2024-23222 类型混淆", active: injector.stageProgress >= 0.3)
                chainStep(number: 2, title: "Wasm 调度劫持", desc: "call_indirect 指针覆盖", active: injector.stageProgress >= 0.4)
                chainStep(number: 3, title: "PAC 绕过", desc: "arm64e GOT-swap 签名伪造", active: injector.stageProgress >= 0.6)
                chainStep(number: 4, title: "沙盒逃逸", desc: "mach_vm_allocate RWX", active: injector.stageProgress >= 0.7)
                chainStep(number: 5, title: "内核 R/W", desc: "CVE-2023-41974 IOSurface", active: injector.stageProgress >= 0.8)
                chainStep(number: 6, title: "AMFI 补丁", desc: "启用 Developer Mode", active: injector.stageProgress >= 0.9)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private func chainStep(number: Int, title: String, desc: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(active ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.caption2.bold())
                    .foregroundColor(active ? .white : .secondary)
            }
            VStack(alignment: .leading) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(active ? .primary : .secondary)
                Text(desc)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
    }

    // MARK: - 操作按钮
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: { showWarning = true }) {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("启动网页注入")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(canStart ? Color.blue : Color.gray)
                .cornerRadius(14)
            }
            .disabled(!canStart)

            if injector.currentStage != .idle {
                Button(action: { injector.stop() }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("停止")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(14)
                }
            }

            if !injector.lastError.isEmpty {
                Text("错误: \(injector.lastError)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var canStart: Bool {
        isDeviceCompatible &&
        selectedApp != nil &&
        !selectedDylib.isEmpty &&
        (injector.currentStage == .idle || injector.currentStage == .failed || injector.currentStage == .crashed)
    }

    // MARK: - 数据加载
    private func loadApps() {
        // 复用 AppCatalog 加载应用列表
        DispatchQueue.global().async {
            let apps = AppCatalog.shared.loadedApps
            DispatchQueue.main.async {
                availableApps = apps
            }
        }
    }

    private func loadDylibs() {
        // 从 Documents/dylibs 目录扫描可用的 dylib
        let docsPath = NSHomeDirectory() + "/Documents/dylibs"
        let fileManager = FileManager.default
        if let files = try? fileManager.contentsOfDirectory(atPath: docsPath) {
            availableDylibs = files.filter { $0.hasSuffix(".dylib") || $0.hasSuffix(".deb") }.map {
                docsPath + "/" + $0
            }
        }
    }

    private func startInjection() {
        guard let app = selectedApp else { return }
        showWebView = true
        injector.startExploit(targetApp: app.bundleID, dylibPath: selectedDylib)
    }
}

// MARK: - App 选择器 Sheet
struct AppPickerSheet: View {
    let apps: [AppCatalog.AppEntry]
    @Binding var selectedApp: AppCatalog.AppEntry?
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List(apps) { app in
                Button(action: {
                    selectedApp = app
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "app")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(app.name)
                                .foregroundColor(.primary)
                            Text(app.bundleID)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if selectedApp?.bundleID == app.bundleID {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("选择目标 App")
            .navigationBarItems(trailing: Button("关闭") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// MARK: - Dylib 选择器 Sheet
struct DylibPickerSheet: View {
    let dylibs: [String]
    @Binding var selectedDylib: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List(dylibs, id: \.self) { dylib in
                Button(action: {
                    selectedDylib = dylib
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "square.stack.3d")
                            .foregroundColor(.purple)
                        Text((dylib as NSString).lastPathComponent)
                            .foregroundColor(.primary)
                        Spacer()
                        if selectedDylib == dylib {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("选择 Dylib")
            .navigationBarItems(trailing: Button("关闭") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// MARK: - Exploit WebView 容器
struct CorunaExploitWebView: UIViewRepresentable {
    let injector: CorunaWebInjector

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 加载 exploit 页面
        injector.startExploit(targetApp: injector.targetBundleID, dylibPath: injector.selectedDylibPath)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("Coruna exploit 页面加载完成")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("Coruna 页面加载失败: \(error)")
        }
    }
}
