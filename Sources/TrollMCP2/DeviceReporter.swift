//
//  DeviceReporter.swift
//  TrollAgent
//
//  启动时上报设备信息到统计后台，用于安装量/机型分布统计。
//  同一设备只上报一次（按 vendorID 去重），后续启动只更新 last_seen。
//

import Foundation
import UIKit

final class DeviceReporter {
    static let shared = DeviceReporter()

    /// 上报服务器地址，例如 https://your-domain.com
    /// 在 设置 → 统计上报 中配置，UserDefaults key: "stats_server_url"
    private var serverURL: String {
        UserDefaults.standard.string(forKey: "stats_server_url") ?? ""
    }

    /// 是否启用上报
    private var enabled: Bool {
        UserDefaults.standard.bool(forKey: "stats_report_enabled")
    }

    private init() {}

    /// App 启动时调用，异步上报设备信息
    func reportIfNeeded() {
        guard enabled else { return }
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/register") else { return }

        let device = UIDevice.current
        let vendorID = device.identifierForVendor?.uuidString ?? UUID().uuidString

        // 读取 App 版本
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"

        // 设备型号（需要从 sysctlbyname 获取，如 iPhone14,5）
        let modelName = Self.deviceModelIdentifier()

        let payload: [String: Any] = [
            "device_uuid": vendorID,
            "device_model": modelName,
            "device_name": device.name,
            "ios_version": device.systemVersion,
            "app_version": appVersion,
            "bundle_id": bundleId
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, _, _ in
            // 静默上报，失败不重试（下次启动再试）
        }.resume()
    }

    // MARK: - 设备型号识别

    /// 获取设备型号标识符，如 "iPhone14,5"（iPhone 13）
    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}
