import Foundation
import UIKit

// v2.9.68：自动更新管理器
// v4.3.30：多源检测——GitHub 被墙（国内常态）时自动切换备用源：
//   检查源链：GitHub API(最新成功构建) → jsDelivr CDN(主分支 plist) → 镜像代理(ghfast/gh-proxy 等)
//   下载源链：GitHub artifact → GitHub 滚动 Release(latest) → 各镜像前缀直连/代理
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    /// v4.3.39：新版红点——启动静默检查发现新版时点亮，设置页"检查更新"行显示红点；用户主动检查或安装成功后熄灭
    @Published var hasUpdateRedDot = false
    @Published var errorMessage: String?
    @Published var downloadedIPAURL: URL?
    /// v4.3.35：自动安装成功提示（副标题/状态行显示"已自动安装"）
    @Published var installMessage: String?
    /// v4.3.30：本次检查命中的源（GitHub / jsDelivr / 镜像），副标题可显示
    @Published var lastSource: String?

    /// v4.3.29：检查时记住最新成功构建 run，下载用同一个（旧逻辑下载时重新查 run，可能拿到别的 workflow）
    private var latestRunId: Int?
    /// v4.3.29：检查时记住 artifact 下载 URL（下载链第一候选）
    private var artifactDownloadURL: String?
    /// v4.3.29：保留下载进度观察者（不持有会被立即释放，进度不更新）
    private var progressObserver: NSKeyValueObservation?

    // v2.9.108：仓库与工作流改为动态读取（对齐 GitHub 账号页配置）
    private var repo: String {
        let owner = UserDefaults.standard.string(forKey: "trollmcp2.github_repo_owner") ?? "zrrt"
        let name = UserDefaults.standard.string(forKey: "trollmcp2.github_repo_name") ?? "trollmcp2"
        return "\(owner)/\(name)"
    }
    private var workflow: String {
        UserDefaults.standard.string(forKey: "trollmcp2.github_workflow_id") ?? "build-trollmcp2.yml"
    }

    // MARK: - 镜像源配置（v4.3.30）

    /// 默认镜像（国内可访问的 GitHub 代理，用于被墙时检查与下载；可在设置里改）
    static let defaultMirrors = ["https://ghfast.top/", "https://gh-proxy.com/"]
    var mirrors: [String] {
        let raw = UserDefaults.standard.string(forKey: "trollmcp2.update_mirrors") ?? ""
        let custom = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && ($0.hasPrefix("http://") || $0.hasPrefix("https://")) }
        return custom.isEmpty ? Self.defaultMirrors : custom
    }
    var mirrorsText: String { mirrors.joined(separator: ",") }
    func saveMirrors(_ text: String) {
        UserDefaults.standard.set(text.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "trollmcp2.update_mirrors")
    }

    private init() {}

    /// 带 token（如已登录 GitHub 账号）的请求
    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = GitHubAccountStore.shared.activeToken {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 发起请求，回调 (data, httpStatus, error)
    private func perform(_ url: URL, timeout: TimeInterval = 25,
                         completion: @escaping (Data?, Int, Error?) -> Void) {
        var request = authorizedRequest(url)
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, resp, error in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion(data, status, error)
        }.resume()
    }

    // MARK: - 检查更新（v4.3.30 多源链）

    /// 检查更新：源1 GitHub API → 源2 jsDelivr CDN → 源3 镜像代理。
    /// 完成回调传是否发现新版本。
    func checkForUpdate(currentVersion: String, completion: ((Bool) -> Void)? = nil) {
        isChecking = true
        errorMessage = nil
        lastSource = nil
        checkViaGitHub(currentVersion: currentVersion, completion: completion)
    }

    /// 源1：GitHub API（最准——只看最新成功构建）
    private func checkViaGitHub(currentVersion: String, completion: ((Bool) -> Void)?) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs?workflow_id=\(workflow)&status=success&per_page=5") else {
            checkViaJsDelivr(currentVersion: currentVersion, completion: completion)
            return
        }
        perform(url) { [weak self] data, status, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard error == nil, status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let runs = json["workflow_runs"] as? [[String: Any]],
                      let latestRun = runs.first else {
                    // GitHub 不可达（被墙/限流/私有仓库未登录）→ 换源
                    self.checkViaJsDelivr(currentVersion: currentVersion, completion: completion)
                    return
                }
                self.latestRunId = latestRun["id"] as? Int
                let sha = (latestRun["head_sha"] as? String) ?? ""
                let title = (latestRun["display_title"] as? String) ?? ""
                // 顺手记下 artifact 下载 URL（下载链第一候选）
                self.fetchArtifactDownloadURL(runId: self.latestRunId)
                self.fetchVersionAtSHA(sha, title: title, currentVersion: currentVersion,
                                       source: "GitHub", completion: completion)
            }
        }
    }

    private func fetchArtifactDownloadURL(runId: Int?) {
        guard let runId = runId,
              let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs/\(runId)/artifacts") else { return }
        perform(url, timeout: 15) { [weak self] data, status, _ in
            DispatchQueue.main.async {
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let artifacts = json["artifacts"] as? [[String: Any]],
                      let first = artifacts.first,
                      let dl = first["archive_download_url"] as? String else { return }
                self?.artifactDownloadURL = dl
            }
        }
    }

    /// 源2：jsDelivr CDN（国内可直连，读主分支 Support/Info.plist 拿版本）
    private func checkViaJsDelivr(currentVersion: String, completion: ((Bool) -> Void)?) {
        let parts = repo.split(separator: "/")
        guard parts.count == 2,
              let url = URL(string: "https://cdn.jsdelivr.net/gh/\(parts[0])/\(parts[1])@main/Support/Info.plist") else {
            checkViaMirror(currentVersion: currentVersion, completion: completion)
            return
        }
        perform(url) { [weak self] data, status, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error != nil || status != 200 || data == nil {
                    self.checkViaMirror(currentVersion: currentVersion, completion: completion)
                    return
                }
                if let v = self.parseVersion(from: data!) {
                    self.latestRunId = nil
                    self.artifactDownloadURL = nil
                    self.applyVersion(v, currentVersion: currentVersion, source: "jsDelivr", completion: completion)
                } else {
                    self.checkViaMirror(currentVersion: currentVersion, completion: completion)
                }
            }
        }
    }

    /// 源3：镜像代理（把 GitHub API + raw 请求套上镜像前缀逐个试）
    private func checkViaMirror(currentVersion: String, completion: ((Bool) -> Void)?) {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else {
            finishCheckFail(completion: completion)
            return
        }
        let mirrors = self.mirrors
        guard !mirrors.isEmpty else {
            finishCheckFail(completion: completion)
            return
        }
        tryMirror(index: 0, mirrors: mirrors, parts: parts, currentVersion: currentVersion, completion: completion)
    }

    private func tryMirror(index: Int, mirrors: [String], parts: [Substring], currentVersion: String, completion: ((Bool) -> Void)?) {
        guard index < mirrors.count else {
            finishCheckFail(completion: completion)
            return
        }
        let mirror = mirrors[index]
        guard let runsURL = URL(string: "\(mirror)https://api.github.com/repos/\(repo)/actions/runs?workflow_id=\(workflow)&status=success&per_page=5") else {
            tryMirror(index: index + 1, mirrors: mirrors, parts: parts, currentVersion: currentVersion, completion: completion)
            return
        }
        perform(runsURL) { [weak self] data, status, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard error == nil, status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let runs = json["workflow_runs"] as? [[String: Any]],
                      let latestRun = runs.first else {
                    self.tryMirror(index: index + 1, mirrors: mirrors, parts: parts,
                                   currentVersion: currentVersion, completion: completion)
                    return
                }
                let runId = latestRun["id"] as? Int
                let sha = (latestRun["head_sha"] as? String) ?? ""
                let title = (latestRun["display_title"] as? String) ?? ""
                self.latestRunId = runId
                self.fetchArtifactDownloadURL(runId: runId)
                // 经镜像读 raw plist
                guard let plistURL = URL(string: "\(mirror)https://raw.githubusercontent.com/\(self.repo)/\(sha)/Support/Info.plist") else {
                    self.tryMirror(index: index + 1, mirrors: mirrors, parts: parts,
                                   currentVersion: currentVersion, completion: completion)
                    return
                }
                self.perform(plistURL) { data2, status2, error2 in
                    DispatchQueue.main.async {
                        if error2 == nil, status2 == 200, let v = data2.flatMap({ self.parseVersion(from: $0) }) {
                            self.applyVersion(v, currentVersion: currentVersion, source: "镜像", completion: completion)
                        } else {
                            // plist 读不到就用 run 标题里的 vX.Y.Z 回退
                            let v = self.extractVersion(from: title)
                            if v == title {
                                self.tryMirror(index: index + 1, mirrors: mirrors, parts: parts,
                                               currentVersion: currentVersion, completion: completion)
                            } else {
                                self.applyVersion(v, currentVersion: currentVersion, source: "镜像", completion: completion)
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishCheckFail(completion: ((Bool) -> Void)?) {
        isChecking = false
        errorMessage = "检查更新失败：GitHub 与备用源均不可达（可能被墙）。可在「更新镜像源」里配置可用镜像。"
        completion?(false)
    }

    /// 从 GitHub 最新构建 commit 的 Support/Info.plist 读版本号（v4.3.29 起；artifact 名无版本号）
    private func fetchVersionAtSHA(_ sha: String, title: String, currentVersion: String,
                                   source: String, completion: ((Bool) -> Void)?) {
        guard !sha.isEmpty, let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(sha)/Support/Info.plist") else {
            let v = extractVersion(from: title)
            if v == title {
                checkViaJsDelivr(currentVersion: currentVersion, completion: completion)
            } else {
                applyVersion(v, currentVersion: currentVersion, source: source, completion: completion)
            }
            return
        }
        perform(url) { [weak self] data, status, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if status == 200, let data = data, let v = self.parseVersion(from: data) {
                    self.applyVersion(v, currentVersion: currentVersion, source: source, completion: completion)
                } else {
                    // raw 不可达 → 换源链继续
                    self.checkViaJsDelivr(currentVersion: currentVersion, completion: completion)
                }
            }
        }
    }

    private func parseVersion(from data: Data) -> String? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            return plist["CFBundleShortVersionString"] as? String
        }
        return nil
    }

    private func applyVersion(_ v: String, currentVersion: String, source: String, completion: ((Bool) -> Void)?) {
        isChecking = false
        lastSource = source
        latestVersion = v
        let newer = isVersionNewer(v, than: currentVersion)
        updateAvailable = newer
        // v4.3.39：发现新版即点亮红点（启动静默检查/手动检查均生效）
        if newer { hasUpdateRedDot = true }
        completion?(newer)
    }

    private func extractVersion(from name: String) -> String {
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

    /// 一键更新：检查（多源）→ 有新版自动下载（多源）→ 调起 TrollStore 安装
    func updateNow(currentVersion: String) {
        // v4.3.39：用户主动点检查更新 = 已看到红点，先熄灭
        hasUpdateRedDot = false
        checkForUpdate(currentVersion: currentVersion) { [weak self] newer in
            guard let self = self else { return }
            if newer {
                self.downloadAndInstall()
            } else if self.errorMessage == nil {
                self.errorMessage = "已是最新版本 v\(currentVersion)"
            }
        }
    }

    // MARK: - 下载 + 安装（v4.3.30 多源链）

    /// 下载链：GitHub artifact(直连) → 滚动 Release(latest, 直连) → 各镜像前缀 × (artifact / Release)
    func downloadAndInstall() {
        guard let version = latestVersion else {
            errorMessage = "请先检查更新"
            return
        }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        let releaseURL = "https://github.com/\(repo)/releases/download/latest/TrollAgent.tipa"
        var attempts: [(url: String, isArtifact: Bool)] = []
        if let art = artifactDownloadURL { attempts.append((art, true)) }
        attempts.append((releaseURL, false))
        for m in mirrors {
            if let art = artifactDownloadURL { attempts.append((m + art, true)) }
            attempts.append((m + releaseURL, false))
        }
        attemptDownload(attempts, index: 0, version: version)
    }

    private func attemptDownload(_ attempts: [(url: String, isArtifact: Bool)], index: Int, version: String) {
        guard index < attempts.count else {
            isDownloading = false
            errorMessage = "所有下载源都失败了（GitHub 可能被墙，可在「更新镜像源」配置可用镜像）"
            return
        }
        let attempt = attempts[index]
        guard let url = URL(string: attempt.url) else {
            attemptDownload(attempts, index: index + 1, version: version)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let task = URLSession.shared.downloadTask(with: req) { [weak self] tempURL, resp, error in
            guard let self = self else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || status != 200 || tempURL == nil {
                DispatchQueue.main.async {
                    self.attemptDownload(attempts, index: index + 1, version: version)
                }
                return
            }
            // v4.3.38: 解压+安装挪后台线程——之前整个 processDownloaded (含同步阻塞等待安装, 最长240s)
            // 跑在 DispatchQueue.main.async 里, 主线程无响应超过 iOS watchdog 阈值会被系统杀进程 (表现为"检查更新闪退")。
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = self.processDownloaded(tempURL!, isArtifact: attempt.isArtifact, version: version)
                if !ok {
                    DispatchQueue.main.async {
                        self.attemptDownload(attempts, index: index + 1, version: version)
                    }
                }
            }
        }
        progressObserver = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.downloadProgress = p.fractionCompleted }
        }
        task.resume()
    }

    /// 处理下载结果：artifact zip → 解压出 TrollAgent.tipa；Release 资产 → tipa 本体。
    /// 返回是否成功（失败则由下载链换下一个源）。
    private func processDownloaded(_ tempURL: URL, isArtifact: Bool, version: String) -> Bool {
        do {
            let data = try Data(contentsOf: tempURL)
            let names = (try? ZipExtractor.entries(data).map { $0.name }) ?? []
            var finalURL: URL?
            if names.contains("TrollAgent.tipa") {
                // GitHub artifact zip（内含 tipa）
                let zipPath = tempURL.appendingPathExtension("zip")
                if FileManager.default.fileExists(atPath: zipPath.path) { try FileManager.default.removeItem(at: zipPath) }
                try FileManager.default.moveItem(at: tempURL, to: zipPath)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ta-update-\(Int(Date().timeIntervalSince1970))")
                try ZipExtractor.unzip(zipPath, to: dir)
                try? FileManager.default.removeItem(at: zipPath)
                finalURL = dir.appendingPathComponent("TrollAgent.tipa")
            } else if names.contains(where: { $0.hasPrefix("Payload/") }) || !isArtifact {
                // tipa 本体（zip 含 Payload/）
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("TrollAgent-v\(version).tipa")
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                finalURL = dest
            } else {
                // 既不是 artifact zip 也不是 tipa（镜像返回错误页等）→ 换源
                return false
            }
            guard let f = finalURL, FileManager.default.fileExists(atPath: f.path) else { return false }
            isDownloading = false
            downloadedIPAURL = f
            installIPA(at: f)
            return true
        } catch {
            return false
        }
    }

    /// v4.3.35: 自动安装——优先 trollstorehelper 静默安装(同 app install/inject_package 通道)，
    /// 不再只弹系统分享菜单让用户手动"用 TrollStore 打开"。
    func installIPA(at url: URL) {
        // 1) 找 trollstorehelper（v4.3.64：懒查单 App 路径，不再全量枚举——对齐 TrollFools 干净枚举）
        var helper = "/var/usr/bin/trollstorehelper"
        let tsPath = AppCatalog.lookupBundlePath(bundleId: "com.opa334.TrollStore") ?? ""
        if !tsPath.isEmpty {
            let candidates = [tsPath + "/trollstorehelper", tsPath + "/TrollStore.app/trollstorehelper",
                              (tsPath as NSString).deletingLastPathComponent + "/trollstorehelper"]
            helper = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? helper
        }
        if FileManager.default.fileExists(atPath: helper) {
            let (code, out) = InjectionManager.shared.spawnRoot(helper, args: ["install", "installd", "force", url.path], timeout: 240)
            // v4.3.24: 184=app has additional encrypted binaries (子 framework 加密由系统解密, 非致命) 182=developer mode
            if code == 0 || code == 184 || code == 182 {
                isDownloading = false
                downloadedIPAURL = nil
                updateAvailable = false
                // v4.3.39：已自动安装 → 红点熄灭
                hasUpdateRedDot = false
                var suffix = ""
                if code == 184 { suffix = " (子二进制加密, 非致命)" }
                else if code == 182 { suffix = " (developer mode)" }
                installMessage = "已自动安装 v\(latestVersion ?? "")\(suffix)"
                return
            }
            // 2) 静默安装失败 → 降级分享菜单(用户手动选 TrollStore 打开)。分享 UI 必须主线程
            DispatchQueue.main.async {
                SharePresenter.present([url]) { [weak self] completed, error in
                    if let error = error {
                        self?.errorMessage = "静默安装失败(exit \(code)), 分享调起也失败: \(error.localizedDescription)"
                    }
                }
            }
            return
        }
        // 3) 无 trollstorehelper → 分享菜单兜底 (UI 必须主线程)
        DispatchQueue.main.async {
            SharePresenter.present([url]) { [weak self] completed, error in
                if let error = error {
                    self?.errorMessage = "安装调起失败: \(error.localizedDescription)"
                }
            }
        }
    }
}
