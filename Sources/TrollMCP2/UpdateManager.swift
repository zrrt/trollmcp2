import Foundation
import UIKit

// v2.9.68：自动更新管理器
// 检查 GitHub CI 最新构建，下载 IPA，调起 TrollStore 安装
// v4.3.29：修复"永远检查不到更新"根因（artifact 名不含版本号，旧逻辑版本比较恒为 false）；
//   版本号改为读取最新成功构建 commit 的 Support/Info.plist；一键更新（检查→下载→调起安装）。
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var errorMessage: String?
    @Published var downloadedIPAURL: URL?

    /// v4.3.29：检查时记住最新成功构建 run，下载用同一个（旧逻辑下载时重新查 run，可能拿到别的 workflow）
    private var latestRunId: Int?
    /// v4.3.29：保留下载进度观察者（不持有会被立即释放，进度不更新）
    private var progressObserver: NSKeyValueObservation?

    // v2.9.108：仓库与工作流改为动态读取（对齐 GitHub 账号页配置），
    // 不再硬编码旧私有仓库——自动更新曾因仓库指向错误导致检查/下载失败
    private var repo: String {
        let owner = UserDefaults.standard.string(forKey: "trollmcp2.github_repo_owner") ?? "zrrt"
        let name = UserDefaults.standard.string(forKey: "trollmcp2.github_repo_name") ?? "trollmcp2"
        return "\(owner)/\(name)"
    }
    private var workflow: String {
        UserDefaults.standard.string(forKey: "trollmcp2.github_workflow_id") ?? "build-trollmcp2.yml"
    }

    private init() {}

    /// v2.9.87：仓库为私有，所有 GitHub API 请求必须带已登录账号的 token，
    /// 否则 runs/artifacts 列表返回 401/404、artifact 下载返回 403。
    private func githubToken() -> String? {
        GitHubAccountStore.shared.activeToken
    }

    private func authorizedRequest(_ url: URL) -> URLRequest? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = githubToken() {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - 检查更新（v4.3.29 重写）

    /// 检查更新：查 build-trollmcp2 workflow 最新成功构建 → 读该 commit 的 Support/Info.plist 版本号。
    /// 完成回调传是否发现新版本（供一键更新链使用）。
    func checkForUpdate(currentVersion: String, completion: ((Bool) -> Void)? = nil) {
        isChecking = true
        errorMessage = nil

        // v4.3.29：workflow_id 限定主构建（旧逻辑不限定，可能拿 build-tweak 的 run 当版本源）
        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs?workflow_id=\(workflow)&status=success&per_page=5")!
        guard let request = authorizedRequest(url) else {
            isChecking = false
            errorMessage = "请先在 GitHub 账号中登录（私有仓库需要 token 才能检查更新）"
            completion?(false)
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false
                if let error = error {
                    self.errorMessage = "检查更新失败: \(error.localizedDescription)"
                    completion?(false)
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let runs = json["workflow_runs"] as? [[String: Any]],
                      let latestRun = runs.first else {
                    self.errorMessage = "未找到构建记录"
                    completion?(false)
                    return
                }
                self.latestRunId = latestRun["id"] as? Int
                let sha = (latestRun["head_sha"] as? String) ?? ""
                let title = (latestRun["display_title"] as? String) ?? ""
                self.fetchVersionAtSHA(sha, title: title, currentVersion: currentVersion, completion: completion)
            }
        }.resume()
    }

    /// v4.3.29：从最新构建 commit 的 Support/Info.plist 读版本号（artifact 名"TrollMCP2"不含版本号，
    /// 旧 extractVersion 拿到 "TrollMCP2" → 版本比较恒 false → 永远"已是最新"。改为读真实 plist）。
    /// 失败回退：从 run 标题（commit message）里提取 vX.Y.Z。
    private func fetchVersionAtSHA(_ sha: String, title: String, currentVersion: String, completion: ((Bool) -> Void)?) {
        let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(sha)/Support/Info.plist")!
        guard let request = authorizedRequest(url) else {
            isChecking = false
            errorMessage = "请先在 GitHub 账号中登录"
            completion?(false)
            return
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var version: String?
                if let data = data,
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    version = plist["CFBundleShortVersionString"] as? String
                }
                if version == nil {
                    version = self.extractVersion(from: title)   // 回退：commit 标题 "v4.3.28: ..."
                }
                guard let v = version else {
                    self.errorMessage = "无法解析最新版本号"
                    completion?(false)
                    return
                }
                self.latestVersion = v
                let newer = self.isVersionNewer(v, than: currentVersion)
                self.updateAvailable = newer
                completion?(newer)
            }
        }.resume()
    }

    private func extractVersion(from name: String) -> String {
        // 从 TrollMCP2-v2.9.68 / TrollAgent-v2.9.68 / "v4.3.28: ..." 中提取 X.Y.Z
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

    // MARK: - 一键更新（v4.3.29）

    /// 一键更新：检查 GitHub 最新 → 有新版自动下载 → 调起 TrollStore 安装。
    /// 已是最新则提示。
    func updateNow(currentVersion: String) {
        checkForUpdate(currentVersion: currentVersion) { [weak self] newer in
            guard let self = self else { return }
            if newer {
                self.downloadAndInstall()
            } else if self.errorMessage == nil {
                self.errorMessage = "已是最新版本 v\(currentVersion)"
            }
        }
    }

    // MARK: - 下载 + 安装

    /// 下载最新 IPA（v4.3.29：用检查时记住的 run；artifact zip 解压出 .tipa 再调起 TrollStore）
    func downloadAndInstall() {
        guard let runId = latestRunId else {
            errorMessage = "请先检查更新"
            return
        }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs/\(runId)/artifacts")!
        guard let request = authorizedRequest(url) else {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.errorMessage = "请先在 GitHub 账号中登录"
            }
            return
        }

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
            self.downloadArtifactZip(urlString: downloadUrl)
        }.resume()
    }

    /// v4.3.29：下载 artifact zip（带进度）→ ZipExtractor 解压 → 找到 TrollMCP2.tipa → 安装。
    /// 旧逻辑直接把 zip 当 .ipa 分享，TrollStore 装不了。
    private func downloadArtifactZip(urlString: String) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.errorMessage = "下载链接无效"
            }
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("TrollAgent-artifact-\(stamp).zip")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDownloading = false
                if let error = error {
                    self.errorMessage = "下载失败: \(error.localizedDescription)"
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self.errorMessage = "下载失败 (HTTP \(http.statusCode))：artifact 下载需已登录 GitHub 且该构建存在，请在 GitHub 账号中检查登录状态"
                    return
                }
                guard let tempURL = tempURL else {
                    self.errorMessage = "下载文件不存在"
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                    // artifact zip 内含 TrollMCP2.tipa → 解压出 tipa 再安装
                    let unzipDir = FileManager.default.temporaryDirectory.appendingPathComponent("ta-update-\(stamp)")
                    try ZipExtractor.unzip(destURL, to: unzipDir)
                    try? FileManager.default.removeItem(at: destURL)
                    let tipaURL = unzipDir.appendingPathComponent("TrollMCP2.tipa")
                    guard FileManager.default.fileExists(atPath: tipaURL.path) else {
                        self.errorMessage = "解压后未找到 TrollMCP2.tipa"
                        return
                    }
                    self.downloadedIPAURL = tipaURL
                    self.installIPA(at: tipaURL)
                } catch {
                    self.errorMessage = "保存/解压失败: \(error.localizedDescription)"
                }
            }
        }
        // 进度观察（保留 observer 引用）
        progressObserver = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = p.fractionCompleted
            }
        }
        task.resume()
    }

    /// 调起 TrollStore 安装 IPA（OpenInMenu 直接显示"用 TrollStore 打开"，免分享面板枚举）
    func installIPA(at url: URL) {
        SharePresenter.present([url]) { [weak self] completed, error in
            if let error = error {
                self?.errorMessage = "安装调起失败: \(error.localizedDescription)"
            }
        }
    }
}
