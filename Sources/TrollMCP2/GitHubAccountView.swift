import SwiftUI

/// GitHub 账号 + 线上编译设置页（v2.9.5）
/// 任何人的 GitHub 账号都可登录/切换，用该账号在云端 Actions 编译 tweak。
/// 注意：仅使用 iOS 14 可用 API。
struct GitHubAccountView: View {
    @StateObject private var store = GitHubAccountStore.shared
    @State private var showAdd = false
    @State private var tweakName = "CompileProbe"
    @State private var busyMessage: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section(header: SettingSectionHeader(title: "当前账号")) {
                if let acct = store.activeAccount {
                    HStack(spacing: 12) {
                        AvatarView(login: acct.login, url: acct.avatarURL)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acct.name ?? acct.login).font(.headline)
                            Text("@\(acct.login)").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if store.isVerifying {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .foregroundColor(.secondary)
                        Text("未登录").foregroundColor(.secondary)
                        Spacer()
                    }
                }

                SettingRowButton(
                    title: store.activeAccount == nil ? "登录 GitHub 账号" : "添加 / 切换账号",
                    subtitle: "使用 Personal Access Token（PAT）",
                    icon: "person.badge.plus",
                    color: .blue
                ) { showAdd = true }
            }

            if !store.accounts.isEmpty {
                Section(header: SettingSectionHeader(title: "已保存账号（点击切换 · 长按删除）")) {
                    ForEach(store.accounts) { acct in
                        Button {
                            store.switchTo(acct.login)
                            toast = "已切换为 @\(acct.login)"
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(login: acct.login, url: acct.avatarURL)
                                    .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(acct.name ?? acct.login).font(.body)
                                    Text("@\(acct.login)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if store.activeLogin == acct.login {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                } else {
                                    Image(systemName: "person.circle").foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contextMenu {
                            Button {
                                store.remove(acct.login)
                                toast = "已删除 @\(acct.login)"
                            } label: {
                                Label("删除账号", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section(header: SettingSectionHeader(title: "线上编译（GitHub Actions）")) {
                TextField("tweak 目录名（如 CompileProbe）", text: $tweakName)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))

                SettingRowButton(
                    title: "触发线上编译",
                    subtitle: store.activeAccount == nil ? "请先登录账号" : "\(store.repoOwner)/\(store.repoName) · workflow=\(store.workflowId)",
                    icon: "hammer.fill",
                    color: .orange
                ) {
                    guard store.activeAccount != nil else {
                        toast = "请先登录 GitHub 账号"; return
                    }
                    busyMessage = "正在触发 \(tweakName) 编译…"
                    store.triggerBuild(tweak: tweakName) { ok, msg in
                        busyMessage = nil
                        toast = ok ? msg : (msg ?? "触发失败")
                        if ok { store.fetchRuns { _ in } }
                    }
                }
                .disabled(store.activeAccount == nil || store.isTriggering)

                if store.isTriggering {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("触发中…").font(.caption).foregroundColor(.secondary)
                    }
                }

                NavigationLink(destination: GitHubRepoSettingsView()) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.blue)
                                .frame(width: 34, height: 34)
                            Image(systemName: "server.rack")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("仓库与 workflow 设置").font(.body)
                            Text("\(store.repoOwner)/\(store.repoName) · \(store.workflowId) · \(store.branch)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section(header: SettingSectionHeader(title: "最近编译记录")) {
                if store.runs.isEmpty {
                    HStack {
                        Text("暂无记录").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("刷新") {
                            store.fetchRuns { _ in }
                        }
                        .font(.caption)
                    }
                } else {
                    ForEach(store.runs) { run in
                        HStack {
                            Text(run.statusText).font(.body)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(run.displayTitle).font(.caption).lineLimit(1)
                                Text("#\(run.id) · \(shortTime(run.createdAt))").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    Button("刷新状态") {
                        store.fetchRuns { _ in }
                    }
                    .font(.footnote)
                    .foregroundColor(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("GitHub 账号")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            AddGitHubAccountView(initialToken: "")
        }
        .onAppear {
            store.fetchRuns { _ in }
        }
        .onChange(of: store.lastError) { err in
            if let err = err { toast = err }
        }
        // busy overlay（iOS14 兼容：无 alignment 参数）
        .overlay(busyOverlay)
        .overlay(bottomToast, alignment: .bottom)
    }

    @ViewBuilder private var busyOverlay: some View {
        if let msg = busyMessage {
            VStack(spacing: 10) {
                ProgressView()
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground).opacity(0.95)))
            .shadow(radius: 8)
        }
    }

    @ViewBuilder private var bottomToast: some View {
        if let msg = toast {
            Text(msg)
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color(.systemGray5)))
                .padding(.bottom, 8)
        }
    }

    private func shortTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: d)
    }
}

// MARK: - 头像（首字母兜底，避免额外网络图片依赖）

struct AvatarView: View {
    let login: String
    let url: String?

    var body: some View {
        ZStack {
            Circle().fill(avatarColor(login))
            Text(String(login.prefix(1)).uppercased())
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private func avatarColor(_ s: String) -> Color {
        let hue = Double(abs(s.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

// MARK: - 添加账号（PAT 登录）

struct AddGitHubAccountView: View {
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var store = GitHubAccountStore.shared
    @State private var token = ""
    @State private var errorMsg: String?
    @State private var loading = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: SettingSectionHeader(title: "GitHub Personal Access Token (PAT)"),
                        footer: Text("在 github.com → Settings → Developer settings → Personal access tokens → Tokens (classic) 生成，勾选 repo 与 workflow 权限。App 仅在你本机保存 token，用于触发线上编译与查询状态。")) {
                    SecureField("ghp_…", text: $token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if let err = errorMsg {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("登录 GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if loading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("登录") {
                            login()
                        }
                        .disabled(token.isEmpty)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func login() {
        loading = true
        errorMsg = nil
        store.verifyAndLogin(token: token.trimmingCharacters(in: .whitespacesAndNewlines)) { ok, msg in
            loading = false
            if ok {
                presentationMode.wrappedValue.dismiss()
            } else {
                errorMsg = msg
            }
        }
    }
}

// MARK: - 仓库与 workflow 设置

struct GitHubRepoSettingsView: View {
    @StateObject private var store = GitHubAccountStore.shared
    @State private var saved = false

    var body: some View {
        Form {
            Section(header: SettingSectionHeader(title: "目标仓库"),
                    footer: Text("线上编译在指定仓库的 Actions 中运行。仓库须包含 build-tweak workflow，且当前账号对该仓库有写权限。")) {
                TextField("仓库 Owner（用户名）", text: $store.repoOwner)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("仓库名", text: $store.repoName)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("workflow 文件名", text: $store.workflowId)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("分支", text: $store.branch)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Section {
                Button("保存") {
                    store.persistNow()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        saved = false
                    }
                }
                if saved {
                    Text("已保存 ✓").font(.footnote).foregroundColor(.green)
                }
            }
        }
        .navigationTitle("仓库设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
