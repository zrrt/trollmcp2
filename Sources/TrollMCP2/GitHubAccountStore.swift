import Foundation
import Combine

// MARK: - GitHub 账号模型

struct GitHubAccount: Codable, Identifiable, Equatable {
    var login: String
    var name: String?
    var avatarURL: String?
    var token: String
    var id: String { login }
}

/// GitHub Actions run 摘要（用于线上编译状态展示）
struct GitHubRun: Identifiable {
    let id: Int
    let status: String          // queued / in_progress / completed
    let conclusion: String?     // success / failure / null
    let createdAt: String
    let headBranch: String
    let displayTitle: String

    var statusText: String {
        switch status {
        case "completed":
            return (conclusion ?? "unknown") == "success" ? "✅ 完成" : "❌ \(conclusion ?? "失败")"
        case "in_progress": return "⏳ 编译中"
        default: return "🕐 排队中"
        }
    }
}

// MARK: - GitHub 账号 + 线上编译（v2.9.5）

/// 管理多个 GitHub 账号：PAT 登录 / 切换 / 删除 / 触发线上编译 workflow / 查询 run 状态。
/// Token 存 UserDefaults（与项目 GatewayClient 同款策略；TrollStore 下 Keychain 受 entitlements 限制不可靠）。
final class GitHubAccountStore: ObservableObject {
    static let shared = GitHubAccountStore()

    @Published private(set) var accounts: [GitHubAccount] = []
    @Published var activeLogin: String?
    @Published var isVerifying = false
    @Published var isTriggering = false
    @Published var lastError: String?
    @Published private(set) var runs: [GitHubRun] = []

    // 目标仓库（可在设置页修改；默认 trollmcp2 仓库 + build-tweak workflow）
    @Published var repoOwner: String
    @Published var repoName: String
    @Published var workflowId: String
    @Published var branch: String

    private let accountsKey = "trollmcp2.github_accounts"
    private let activeKey = "trollmcp2.github_active"
    private let ownerKey = "trollmcp2.github_repo_owner"
    private let repoKey = "trollmcp2.github_repo_name"
    private let workflowKey = "trollmcp2.github_workflow_id"
    private let branchKey = "trollmcp2.github_branch"

    private let apiBase = "https://api.github.com"

    init() {
        let def = UserDefaults.standard
        repoOwner = def.string(forKey: ownerKey) ?? "origina47487lhe-droid"
        repoName = def.string(forKey: repoKey) ?? "trollmcp2"
        workflowId = def.string(forKey: workflowKey) ?? "build-tweak"
        branch = def.string(forKey: branchKey) ?? "main"
        load()
    }

    // MARK: - 账号访问

    var activeAccount: GitHubAccount? {
        guard let login = activeLogin else { return nil }
        return accounts.first { $0.login == login }
    }

    var activeToken: String? { activeAccount?.token }

    func token(for login: String) -> String? {
        accounts.first { $0.login == login }?.token
    }

    // MARK: - 持久化

    private func load() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let saved = try? JSONDecoder().decode([GitHubAccount].self, from: data) {
            accounts = saved
        }
        activeLogin = UserDefaults.standard.string(forKey: activeKey)
        if let l = activeLogin, !accounts.contains(where: { $0.login == l }) {
            activeLogin = accounts.first?.login
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
        UserDefaults.standard.set(activeLogin, forKey: activeKey)
        let def = UserDefaults.standard
        def.set(repoOwner, forKey: ownerKey)
        def.set(repoName, forKey: repoKey)
        def.set(workflowId, forKey: workflowKey)
        def.set(branch, forKey: branchKey)
    }

    // MARK: - PAT 登录 / 验证

    /// 用 GitHub PAT 验证并登录/更新账号。成功回调 true + 账号 login。
    func verifyAndLogin(token: String, completion: @escaping (Bool, String?) -> Void) {
        guard !token.isEmpty else {
            lastError = "Token 不能为空"
            completion(false, lastError)
            return
        }
        isVerifying = true
        var req = URLRequest(url: URL(string: "\(apiBase)/user")!, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isVerifying = false
                if let err = err {
                    self.lastError = "网络错误: \(err.localizedDescription)"
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let login = json["login"] as? String else {
                    self.lastError = status == 401 ? "Token 无效或已过期（请检查 repo + workflow 权限）"
                        : "GitHub 验证失败 (HTTP \(status))"
                    completion(false, self.lastError)
                    return
                }
                let name = json["name"] as? String
                let avatar = json["avatar_url"] as? String
                let acct = GitHubAccount(login: login, name: name, avatarURL: avatar, token: token)
                if let idx = self.accounts.firstIndex(where: { $0.login == login }) {
                    self.accounts[idx] = acct
                } else {
                    self.accounts.append(acct)
                }
                self.activeLogin = login
                NetworkLog.shared.log("GitHub 账号登录: \(login) (HTTP \(status))")
                self.persist()
                completion(true, login)
            }
        }.resume()
    }

    func switchTo(_ login: String) {
        guard accounts.contains(where: { $0.login == login }) else { return }
        activeLogin = login
        persist()
    }

    func remove(_ login: String) {
        accounts.removeAll { $0.login == login }
        if activeLogin == login {
            activeLogin = accounts.first?.login
        }
        persist()
    }

    /// 手动触发持久化（仓库设置页保存按钮）
    func persistNow() {
        persist()
    }

    // MARK: - 线上编译（触发 GitHub Actions）

    func triggerBuild(tweak: String, completion: @escaping (Bool, String?) -> Void) {
        guard let token = activeToken else {
            lastError = "未登录 GitHub 账号"
            completion(false, lastError)
            return
        }
        guard !tweak.isEmpty else {
            lastError = "请填写 tweak 目录名"
            completion(false, lastError)
            return
        }
        isTriggering = true
        var req = URLRequest(url: URL(string: "\(apiBase)/repos/\(repoOwner)/\(repoName)/actions/workflows/\(workflowId)/dispatches")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "ref": branch,
            "inputs": ["tweak": tweak]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTriggering = false
                if let err = err {
                    self.lastError = "网络错误: \(err.localizedDescription)"
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 204 {
                    NetworkLog.shared.log("触发线上编译 \(self.repoOwner)/\(self.repoName) tweak=\(tweak) (HTTP 204)")
                    self.fetchRuns { _ in }
                    completion(true, "已触发 \(tweak) 编译，稍后刷新状态")
                } else if status == 404 {
                    self.lastError = "workflow '\(self.workflowId)' 不存在（请确认仓库里有 build-tweak.yml）"
                    completion(false, self.lastError)
                } else if status == 401 {
                    self.lastError = "Token 无 workflow 权限或已过期"
                    completion(false, self.lastError)
                } else {
                    self.lastError = "触发失败 (HTTP \(status))"
                    completion(false, self.lastError)
                }
            }
        }.resume()
    }

    func fetchRuns(completion: ((Bool) -> Void)? = nil) {
        guard let token = activeToken else { completion?(false); return }
        var req = URLRequest(url: URL(string: "\(apiBase)/repos/\(repoOwner)/\(repoName)/actions/runs?per_page=10&event=workflow_dispatch")!, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self = self else { completion?(false); return }
                if err != nil || data == nil { completion?(false); return }
                guard let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any],
                      let arr = json["workflow_runs"] as? [[String: Any]] else {
                    completion?(false)
                    return
                }
                self.runs = arr.compactMap { d in
                    guard let id = d["id"] as? Int else { return nil }
                    return GitHubRun(
                        id: id,
                        status: d["status"] as? String ?? "unknown",
                        conclusion: d["conclusion"] as? String,
                        createdAt: d["created_at"] as? String ?? "",
                        headBranch: d["head_branch"] as? String ?? "",
                        displayTitle: d["display_title"] as? String ?? "run"
                    )
                }
                completion?(true)
            }
        }.resume()
    }
}
