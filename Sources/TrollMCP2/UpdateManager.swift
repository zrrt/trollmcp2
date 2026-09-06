import Foundation
import UIKit

// v2.9.68：自动更新管理器
// 检查 GitHub CI 最新构建，下载 IPA，调起 TrollStore 安装
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var errorMessage: String?
    @Published var downloadedIPAURL: URL?

    private let repo = "origina47487lhe-droid/trollmcp2"
    private let workflow = "build-trollmcp2"

    private init() {}

    // 检查更新：获取最新成功的 CI run，比较版本号
    func checkForUpdate(currentVersion: String) {
        isChecking = true
        errorMessage = nil

        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs?status=success&per_page=5")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isChecking = false
                if let error = error {
                    self?.errorMessage = "检查更新失败: \(error.localizedDescription)"
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let runs = json["workflow_runs"] as? [[String: Any]] else {
                    self?.errorMessage = "解析更新信息失败"
                    return
                }
                // 找最新的 build-trollmcp2 workflow run
                guard let latestRun = runs.first(where: { ($0["name"] as? String)?.contains("build") ?? false }) ?? runs.first else {
                    self?.errorMessage = "未找到构建记录"
                    return
                }
                let runId = latestRun["id"] as? Int ?? 0
                let runNumber = latestRun["run_number"] as? Int ?? 0
                // 从 artifact 名或 run 信息推断版本
                // 简化：用 run_number 作为版本判断，或者获取 artifact 名
                self?.fetchLatestArtifactVersion(runId: runId, currentVersion: currentVersion)
            }
        }.resume()
    }

    private func fetchLatestArtifactVersion(runId: Int, currentVersion: String) {
        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs/\(runId)/artifacts")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.errorMessage = "获取构建产物失败: \(error.localizedDescription)"
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let artifacts = json["artifacts"] as? [[String: Any]],
                      let artifact = artifacts.first else {
                    self?.errorMessage = "未找到构建产物"
                    return
                }
                let artifactName = artifact["name"] as? String ?? "unknown"
                // artifact 名通常包含版本号，如 TrollAgent-v2.9.73
                let version = self?.extractVersion(from: artifactName) ?? artifactName
                self?.latestVersion = version
                self?.updateAvailable = self?.isVersionNewer(version, than: currentVersion) ?? false
            }
        }.resume()
    }

    private func extractVersion(from name: String) -> String {
        // 从 TrollMCP2-v2.9.68 或 TrollAgent-v2.9.68 中提取 2.9.68
        let pattern = #"v?(\d+\.\d+\.\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let range = Range(match.range(at: 1), in: name) {
            return String(name[range])
        }
        return name
    }

    private func isVersionNewer(_ v1: String, than v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }

    // 下载最新 IPA
    func downloadAndInstall() {
        guard let latestVersion = latestVersion else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        // 先获取最新 artifact 的下载 URL
        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs?status=success&per_page=1")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.errorMessage = "获取下载链接失败: \(error.localizedDescription)"
                }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runs = json["workflow_runs"] as? [[String: Any]],
                  let runId = runs.first?["id"] as? Int else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.errorMessage = "获取构建ID失败"
                }
                return
            }
            self.downloadArtifact(runId: runId, version: latestVersion)
        }.resume()
    }

    private func downloadArtifact(runId: Int, version: String) {
        // 获取 artifact 下载 URL（需要 token，公开仓库可以用 archive_download_url 重定向）
        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs/\(runId)/artifacts")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.errorMessage = "获取产物失败: \(error.localizedDescription)"
                }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artifacts = json["artifacts"] as? [[String: Any]],
                  let downloadUrl = artifacts.first?["archive_download_url"] as? String else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.errorMessage = "未找到下载链接"
                }
                return
            }
            self.downloadIPA(urlString: downloadUrl, version: version)
        }.resume()
    }

    private func downloadIPA(urlString: String, version: String) {
        guard let url = URL(string: urlString) else { return }
        let destPath = FileManager.default.temporaryDirectory.appendingPathComponent("TrollAgent-v\(version).ipa")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                self?.isDownloading = false
                if let error = error {
                    self?.errorMessage = "下载失败: \(error.localizedDescription)"
                    return
                }
                guard let tempURL = tempURL else {
                    self?.errorMessage = "下载文件不存在"
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: destPath.path) {
                        try FileManager.default.removeItem(at: destPath)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destPath)
                    self?.downloadedIPAURL = destPath
                    self?.installIPA(at: destPath)
                } catch {
                    self?.errorMessage = "保存文件失败: \(error.localizedDescription)"
                }
            }
        }
        // 进度观察
        task.resume()
    }

    // 调起 TrollStore 安装 IPA
    func installIPA(at url: URL) {
        // 方式1：用 TrollStore URL scheme（如果支持）
        // 方式2：用 UIActivityViewController 分享给 TrollStore
        // 方式3：用 UIDocumentInteractionController
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activityVC.completionWithItemsHandler = { [weak self] _, completed, _, error in
            if let error = error {
                self?.errorMessage = "安装调起失败: \(error.localizedDescription)"
            } else if completed {
                // 用户选择了 TrollStore 安装
            }
        }
        // 从根视图控制器弹出
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}
