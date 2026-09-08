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

    // Device Flow 用 OAuth App client_id。
    // 默认值 = 内置共享 Client ID（origina47487lhe-droid 注册的 "TrollMCP2 线上编译" OAuth App，
    // Device Flow 已启用）。任意 GitHub 用户都可借此授权，各自拿自己的 token——新手零配置。
    // 高级用户可在「仓库设置」覆盖为自己的 OAuth App。
    @Published var clientID: String

    // Device Flow 轮询状态
    @Published var deviceFlowState: String?   // 提示文案（含 user_code）
    @Published var isDevicePolling = false
    private var pollTimer: DispatchSourceTimer?   // 持有强引用，防止局部变量被释放导致轮询停止

    private let accountsKey = "trollmcp2.github_accounts"
    private let activeKey = "trollmcp2.github_active"
    private let ownerKey = "trollmcp2.github_repo_owner"
    private let repoKey = "trollmcp2.github_repo_name"
    private let workflowKey = "trollmcp2.github_workflow_id"
    private let branchKey = "trollmcp2.github_branch"
    private let clientIDKey = "trollmcp2.github_client_id"

    private let apiBase = "https://api.github.com"
    private let loginBase = "https://github.com"

    init() {
        let def = UserDefaults.standard
        repoOwner = def.string(forKey: ownerKey) ?? "zrrt"
        repoName = def.string(forKey: repoKey) ?? "trollmcp2"
        workflowId = def.string(forKey: workflowKey) ?? "build-trollmcp2.yml"
        branch = def.string(forKey: branchKey) ?? "main"
        clientID = def.string(forKey: clientIDKey) ?? "Ov23li890n3hM15edlcw"
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
        // v2.9.110：旧配置自动迁移——早期默认指向 origina47487lhe-droid（Actions 配额已耗尽）与
        // build-tweak workflow（已更名 build-trollmcp2.yml）。覆盖安装会保留旧 UserDefaults，
        // 这里检测到旧值自动纠正，避免线上编译 404 / 触发到错误仓库。
        let def = UserDefaults.standard
        if def.string(forKey: ownerKey) == "origina47487lhe-droid" {
            repoOwner = "zrrt"
        }
        if def.string(forKey: workflowKey) == "build-tweak" {
            workflowId = "build-trollmcp2.yml"
        }
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let saved = try? JSONDecoder().decode([GitHubAccount].self, from: data) {
            accounts = saved
        }
        activeLogin = UserDefaults.standard.string(forKey: activeKey)
        if let l = activeLogin, !accounts.contains(where: { $0.login == l }) {
            activeLogin = accounts.first?.login
        }
        persist()   // v2.9.110：迁移后的值落盘，一次性纠正旧配置
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
        def.set(clientID, forKey: clientIDKey)
    }

    // MARK: - Device Flow（内置浏览器登录，gh CLI 同款）

    /// 设备授权码模型
    struct DeviceCode: Codable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    /// 第一步：请求设备授权码。回调返回验证 URL 与 user_code。
    func startDeviceFlow(completion: @escaping (DeviceCode?, String?) -> Void) {
        let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty else {
            lastError = "请先在仓库设置里填写 OAuth App 的 Client ID"
            completion(nil, lastError)
            return
        }
        var req = URLRequest(url: URL(string: "\(loginBase)/login/device/code")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // scope：repo（读仓库+触发 workflow）+ workflow（workflow dispatch 必须）
        let body = "client_id=\(cid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cid)&scope=repo%20workflow"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.lastError = "网络错误: \(err.localizedDescription)"
                    completion(nil, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data = data,
                      let code = try? JSONDecoder().decode(DeviceCode.self, from: data) else {
                    let raw = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
                    self.lastError = status == 404 ? "Client ID 无效（请检查 OAuth App 的 Client ID）" : "设备码请求失败 (HTTP \(status)) \(raw.prefix(200))"
                    completion(nil, self.lastError)
                    return
                }
                self.deviceFlowState = "请在浏览器输入代码 \(code.user_code)"
                NetworkLog.shared.log("GitHub Device Flow 开始: user_code=\(code.user_code)")
                completion(code, nil)
            }
        }.resume()
    }

    /// 第二步：轮询换取 access_token（interval 秒一次，最长 expires_in 秒）。
    func pollDeviceToken(deviceCode: DeviceCode, completion: @escaping (Bool, String?) -> Void) {
        isDevicePolling = true
        deviceFlowState = "请在浏览器输入代码 \(deviceCode.user_code)，等待授权…"

        let deadline = Date().addingTimeInterval(Double(deviceCode.expires_in))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        pollTimer = timer
        timer.schedule(deadline: .now() + Double(deviceCode.interval), repeating: Double(deviceCode.interval))
        timer.setEventHandler { [weak self] in
            guard let self = self else { timer.cancel(); return }
            if Date() > deadline {
                timer.cancel()
                self.pollTimer = nil
                DispatchQueue.main.async {
                    self.isDevicePolling = false
                    self.deviceFlowState = nil
                    completion(false, "授权超时，请重试")
                }
                return
            }
            self.exchangeDeviceToken(deviceCode: deviceCode) { token, error in
                if let token = token {
                    timer.cancel()
                    self.pollTimer = nil
                    DispatchQueue.main.async {
                        self.isDevicePolling = false
                        self.deviceFlowState = nil
                        // 用拿到的 token 走统一验证流程（GET /user + 存储）
                        self.finishLoginWith(token: token) { ok, msg in
                            completion(ok, msg)
                        }
                    }
                } else if error == "authorization_pending" {
                    // 用户还没授权，继续轮询
                } else if error == "slow_down" {
                    // 需要放慢，重新调度会自然多等一个 interval
                } else if let error = error {
                    timer.cancel()
                    self.pollTimer = nil
                    DispatchQueue.main.async {
                        self.isDevicePolling = false
                        self.deviceFlowState = nil
                        completion(false, error)
                    }
                }
            }
        }
        timer.resume()
    }

    private func exchangeDeviceToken(deviceCode: DeviceCode,
                                     completion: @escaping (String?, String?) -> Void) {
        let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = URLRequest(url: URL(string: "\(loginBase)/login/oauth/access_token")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(cid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cid)&device_code=\(deviceCode.device_code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? deviceCode.device_code)&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, _, err in
            if err != nil { completion(nil, "网络错误"); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "响应解析失败")
                return
            }
            if let token = json["access_token"] as? String {
                completion(token, nil)
            } else if let err = json["error"] as? String {
                completion(nil, err)   // authorization_pending / slow_down / expired_token / access_denied
            } else {
                completion(nil, "未知响应")
            }
        }.resume()
    }

    /// 统一登录落库：验证 token 身份 → 加入/更新账号
    private func finishLoginWith(token: String, completion: @escaping (Bool, String?) -> Void) {
        var req = URLRequest(url: URL(string: "\(apiBase)/user")!, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.lastError = "网络错误: \(err.localizedDescription)"
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let login = json["login"] as? String else {
                    self.lastError = "身份验证失败 (HTTP \(status))"
                    completion(false, self.lastError)
                    return
                }
                let acct = GitHubAccount(login: login,
                                         name: json["name"] as? String,
                                         avatarURL: json["avatar_url"] as? String,
                                         token: token)
                if let idx = self.accounts.firstIndex(where: { $0.login == login }) {
                    self.accounts[idx] = acct
                } else {
                    self.accounts.append(acct)
                }
                self.activeLogin = login
                NetworkLog.shared.log("GitHub 网页登录成功: \(login)")
                self.persist()
                completion(true, "已登录 @\(login)")
            }
        }.resume()
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
